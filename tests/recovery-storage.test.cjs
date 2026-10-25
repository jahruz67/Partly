'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { validateScanPayload, validateRecoveryPayload, validateCandidate, freeExtents, scanLostVolumes } = require('../lib/recovery-storage.cjs');

const MIB = 1024 ** 2;
const target = { diskNumber: 7, diskUniqueId: 'recovery-test-disk' };
const snapshot = () => ({ disks: [{ number: 7, uniqueId: target.diskUniqueId, serialNumber: 'TEST', size: 128 * MIB, partitionStyle: 'GPT', partitions: [{ partitionNumber: 1, offset: MIB, size: 16 * MIB, driveLetter: 'D' }] }] });
const scan = (params = {}) => ({ target, expectedSnapshot: snapshot(), params: { offset: 17 * MIB, length: 110 * MIB, deepScan: false, ...params } });
const candidate = (params = {}) => ({ offset: 32 * MIB, size: 16 * MIB, bytesPerSector: 512, fileSystem: 'NTFS', bootHash: 'a'.repeat(64), ...params });
const recovery = (params = {}) => ({ target, expectedSnapshot: snapshot(), params: { candidate: candidate(), driveLetter: 'F', ...params } });

test('recovery scan validates stable identity and restricts the request to unallocated ranges', () => {
  assert.doesNotThrow(() => validateScanPayload(scan()));
  assert.throws(() => validateScanPayload(scan({ offset: 2 * MIB })), /unallocated/);
  assert.throws(() => validateScanPayload(scan({ offset: 127 * MIB, length: 2 * MIB })), /unallocated/);
  assert.throws(() => validateScanPayload(scan({ deepScan: 'true' })), /true or false/);
  assert.throws(() => validateScanPayload({ ...scan(), target: { ...target, diskUniqueId: 'different' } }), /identity/);
  assert.throws(() => validateScanPayload(scan({ offset: MIB + 1 })), /aligned/);
});

test('free recovery extents preserve disk metadata and exclude every current partition', () => {
  const disk = snapshot().disks[0];
  disk.partitions.push({ partitionNumber: 2, offset: 40 * MIB, size: 8 * MIB });
  assert.deepEqual(freeExtents(disk), [{ offset: 17 * MIB, length: 23 * MIB }, { offset: 48 * MIB, length: 79 * MIB }]);
});

test('recovery requires detected header evidence and geometry that does not overlap current data', () => {
  assert.doesNotThrow(() => validateRecoveryPayload(recovery()));
  assert.throws(() => validateCandidate(candidate({ bootHash: '' })), /fingerprint/);
  assert.throws(() => validateCandidate(candidate({ fileSystem: 'random' })), /unsupported/);
  assert.throws(() => validateCandidate(candidate({ size: MIB + 1 })), /aligned/);
  assert.throws(() => validateCandidate(candidate({ recoverable: false })), /verified backup/);
  assert.throws(() => validateRecoveryPayload(recovery({ candidate: candidate({ offset: 2 * MIB }) })), /overlaps/);
  assert.throws(() => validateRecoveryPayload(recovery({ driveLetter: 'D' })), /already in use/);
  assert.throws(() => validateRecoveryPayload(recovery({ driveLetter: 'Z:' })), /drive letter/);
});

test('a scan cancelled before it starts never opens native disk access', { skip: process.platform !== 'win32' }, async () => {
  const controller = new AbortController(); controller.abort();
  const result = await scanLostVolumes(scan(), null, controller.signal);
  assert.equal(result.cancelled, true);
  assert.equal(result.scannedBytes, 0);
});

test('recovery refuses Windows/system disks and unavailable targets before invoking native code', () => {
  for (const key of ['isBoot', 'isSystem', 'isReadOnly', 'isOffline']) {
    const payload = recovery(); payload.expectedSnapshot.disks[0][key] = true;
    assert.throws(() => validateRecoveryPayload(payload), /boot|writable/);
  }
  const payload = recovery(); payload.expectedSnapshot.disks[0].partitions[0].isSystem = true;
  assert.throws(() => validateRecoveryPayload(payload), /system/);
  assert.throws(() => validateRecoveryPayload({ ...recovery(), expectedSnapshot: null }), /snapshot/);
});

function fixture(id, offset, size, fileSystem, options = {}) {
  const bps = options.sectorSize || 512;
  const boot = Buffer.alloc(bps);
  boot.set([0xEB, 0x52, 0x90]); boot[510] = 0x55; boot[511] = 0xAA;
  const blocks = [];
  const add = (location, data) => blocks.push({ offset: location, data: data.toString('base64') });
  if (fileSystem === 'NTFS') {
    boot.write('NTFS    ', 3, 'ascii'); boot.writeUInt16LE(bps, 11); boot[13] = 8; boot[21] = 0xF8;
    boot.writeUInt32LE(offset / bps, 28);
    boot.writeBigUInt64LE(BigInt(size / bps - (options.totalCountConvention ? 0 : 1)), 40);
    boot.writeBigUInt64LE(4n, 48); boot.writeBigUInt64LE(2n, 56); boot[64] = 0xF6; boot[68] = 1;
    add(offset, boot); if (!options.noBackup) add(offset + size - bps, Buffer.from(boot));
    if (!options.noMetadata) { const record = Buffer.alloc(bps); record.write('FILE', 0, 'ascii'); record.writeUInt16LE(48, 4); record.writeUInt16LE(3, 6); record.writeUInt16LE(56, 20); record.writeUInt32LE(100, 24); record.writeUInt32LE(1024, 28); add(offset + 4 * 8 * bps, record); }
  } else if (fileSystem === 'exFAT') {
    boot.write('EXFAT   ', 3, 'ascii'); boot.writeBigUInt64LE(BigInt(offset / bps), 64); boot.writeBigUInt64LE(BigInt(size / bps), 72);
    boot.writeUInt32LE(128, 80); boot.writeUInt32LE(128, 84); boot.writeUInt32LE(512, 88); boot.writeUInt32LE(Math.floor((size / bps - 512) / 8), 92); boot.writeUInt32LE(2, 96);
    boot.writeUInt16LE(0x100, 104); boot[108] = Math.log2(bps); boot[109] = 3; boot[110] = 1; boot[112] = 0;
    const region = Buffer.alloc(12 * bps); boot.copy(region);
    for (let i = 1; i <= 8; i++) region.writeUInt32LE(0xAA550000, (i + 1) * bps - 4);
    let checksum = 0;
    for (let i = 0; i < 11 * bps; i++) { if ([106, 107, 112].includes(i)) continue; checksum = ((((checksum & 1) ? 0x80000000 : 0) + (checksum >>> 1) + region[i]) >>> 0); }
    for (let i = 11 * bps; i < 12 * bps; i += 4) region.writeUInt32LE(checksum, i);
    if (options.badChecksum) region[300] ^= 1;
    add(offset, region); if (!options.noBackup) add(offset + 12 * bps, Buffer.from(region));
    const fat = Buffer.alloc(bps); fat.writeUInt32LE(0xFFFFFFF8, 0); fat.writeUInt32LE(0xFFFFFFFF, 4); add(offset + 128 * bps, fat);
  } else {
    boot.write('MSDOS5.0', 3, 'ascii'); boot.writeUInt16LE(bps, 11); boot[21] = 0xF8; boot.writeUInt32LE(offset / bps, 28);
    const fat32 = fileSystem === 'FAT32', fat12 = fileSystem === 'FAT12';
    const spc = fat32 || fat12 ? 1 : 4, reserved = fat32 ? 32 : 1, fatSize = fat32 ? 1024 : fat12 ? 6 : 32;
    boot[13] = spc; boot.writeUInt16LE(reserved, 14); boot[16] = 2;
    boot.writeUInt16LE(fat32 ? 0 : fat12 ? 224 : 512, 17);
    if (size / bps <= 65535) boot.writeUInt16LE(size / bps, 19); else boot.writeUInt32LE(size / bps, 32);
    if (fat32) { boot.writeUInt32LE(fatSize, 36); boot.writeUInt32LE(2, 44); boot.writeUInt16LE(1, 48); boot.writeUInt16LE(6, 50); boot.write('RECOVERED  ', 71, 'ascii'); boot.write('FAT32   ', 82, 'ascii'); }
    else { boot.writeUInt16LE(fatSize, 22); boot.write('RECOVERED  ', 43, 'ascii'); boot.write(fileSystem.padEnd(8), 54, 'ascii'); }
    add(offset, boot); if (fat32 && !options.noBackup) add(offset + 6 * bps, Buffer.from(boot));
    if (!options.noMetadata) { const fat = Buffer.alloc(bps); fat.set([0xF8, 0xFF, 0xFF, 0x0F]); add(offset + reserved * bps, fat); }
  }
  return { id, offset, length: options.available || size, diskSize: 256 * MIB, sectorSize: bps, blocks, bootHash: createHash('sha256').update(boot).digest('hex') };
}

test('native recovery parser detects actual NTFS/FAT/exFAT structures in memory-only fixtures', { skip: process.platform !== 'win32', timeout: 60000 }, async () => {
  const cases = [
    fixture('ntfs', MIB, 8 * MIB, 'NTFS'),
    fixture('ntfs-count', MIB, 8 * MIB, 'NTFS', { totalCountConvention: true }),
    fixture('ntfs-4kn', MIB, 8 * MIB, 'NTFS', { sectorSize: 4096 }),
    fixture('ntfs-unconfirmed', MIB, 8 * MIB, 'NTFS', { noBackup: true, noMetadata: true }),
    fixture('ntfs-mft-only', MIB, 8 * MIB, 'NTFS', { noBackup: true }),
    fixture('ntfs-too-large', MIB, 8 * MIB, 'NTFS', { available: 4 * MIB }),
    fixture('fat12', MIB, MIB, 'FAT12'),
    fixture('fat16', MIB, 16 * MIB, 'FAT16'),
    fixture('fat32', MIB, 64 * MIB, 'FAT32'),
    fixture('exfat', MIB, 16 * MIB, 'exFAT'),
    fixture('exfat-bad-checksum', MIB, 16 * MIB, 'exFAT', { badChecksum: true }),
  ];
  const deep = fixture('deep-scan', 2 * MIB + 512, 8 * MIB, 'NTFS'); deep.scan = true; deep.deepScan = true; deep.offset = MIB; deep.length = 16 * MIB;
  cases.push(deep);
  const fast = { ...deep, id: 'aligned-scan', deepScan: false }; cases.push(fast);
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'partly20-recovery-fixtures-'));
  try {
    const request = path.join(temporary, 'fixtures.json'); await fs.writeFile(request, JSON.stringify({ cases }));
    const run = spawnSync(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.resolve(__dirname, '../windows/recovery-storage.ps1'), '-Action', 'inspect-fixture', '-PayloadPath', request], { encoding: 'utf8', windowsHide: true, timeout: 55000, maxBuffer: 4 * 1024 * 1024 });
    assert.equal(run.status, 0, run.stdout + '\n' + run.stderr);
    const results = new Map(JSON.parse(run.stdout.replace(/^\uFEFF/, '').trim()).results.map((item) => [item.id, item.result]));
    for (const [id, fileSystem] of [['ntfs', 'NTFS'], ['ntfs-count', 'NTFS'], ['ntfs-4kn', 'NTFS'], ['ntfs-mft-only', 'NTFS'], ['fat12', 'FAT12'], ['fat16', 'FAT16'], ['fat32', 'FAT32'], ['exfat', 'exFAT']]) {
      assert.equal(results.get(id)?.fileSystem, fileSystem, id);
      assert.equal(results.get(id)?.recoverable, true, id + ' independent boot/metadata evidence');
      assert.equal(results.get(id)?.size, cases.find((item) => item.id === id).length, id + ' exact size');
    }
    assert.equal(results.get('ntfs-unconfirmed').recoverable, false);
    assert.equal(results.get('ntfs-too-large'), null);
    assert.equal(results.get('exfat-bad-checksum'), null);
    assert.equal(results.get('deep-scan').candidates.length, 1);
    assert.equal(results.get('deep-scan').candidates[0].offset, 2 * MIB + 512);
    assert.equal(results.get('aligned-scan').candidates.length, 0);
  } finally { await fs.rm(temporary, { recursive: true, force: true }); }
});
