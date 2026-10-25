'use strict';
const {windowsPowerShellEnv}=require('./windows-env.cjs');

// Undelete creates a partition entry over an independently detected existing file system.
// It never creates a new file system or formats a candidate.
const { spawn } = require('node:child_process');
const { existsSync } = require('node:fs');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

const RESOURCE = process.resourcesPath && path.join(process.resourcesPath, 'windows', 'recovery-storage.ps1');
const SCRIPT = RESOURCE && existsSync(RESOURCE) ? RESOURCE : path.resolve(__dirname, '../windows/recovery-storage.ps1');
const MIB = 1024 ** 2;
const FILE_SYSTEMS = new Set(['NTFS', 'FAT12', 'FAT16', 'FAT32', 'exFAT']);
let recovering = false;

function integer(value, name, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) throw new TypeError(`${name} must be a safe whole number.`);
  return value;
}

function validateTarget(target) {
  if (!target || typeof target !== 'object' || Array.isArray(target)) throw new TypeError('Select a disk to scan.');
  integer(target.diskNumber, 'Disk number');
  if (typeof target.diskUniqueId !== 'string' || !target.diskUniqueId.trim() || target.diskUniqueId.length > 512) throw new TypeError('Disk identity is required. Refresh the disk list.');
  return target;
}

function freeExtents(disk, sectorSize = 512) {
  integer(disk?.size, 'Disk size', MIB * 2);
  if (!Array.isArray(disk.partitions)) throw new TypeError('Partition inventory is required.');
  const partitions = [...disk.partitions].sort((a, b) => a.offset - b.offset);
  const extents = [];
  let cursor = MIB;
  const usableEnd = Math.floor((disk.size - MIB) / sectorSize) * sectorSize;
  for (const partition of partitions) {
    integer(partition.offset, 'Partition offset');
    integer(partition.size, 'Partition size', 1);
    if (partition.offset > cursor) extents.push({ offset: cursor, length: partition.offset - cursor });
    cursor = Math.max(cursor, partition.offset + partition.size);
  }
  if (cursor < usableEnd) extents.push({ offset: cursor, length: usableEnd - cursor });
  return extents.map((extent) => {
    const start = Math.ceil(extent.offset / sectorSize) * sectorSize;
    const end = Math.floor(Math.min(usableEnd, extent.offset + extent.length) / sectorSize) * sectorSize;
    return { offset: start, length: end - start };
  }).filter((extent) => extent.length >= sectorSize);
}

function expectedDisk(payload, required = false) {
  const disks = payload.expectedSnapshot?.disks;
  if (!Array.isArray(disks)) {
    if (required) throw new TypeError('A current disk snapshot is required before recovering a volume.');
    return null;
  }
  const matches = disks.filter((disk) => disk.number === payload.target.diskNumber);
  if (matches.length !== 1 || matches[0].uniqueId !== payload.target.diskUniqueId) throw new TypeError('The selected disk identity does not match the snapshot.');
  return matches[0];
}

function validateScanPayload(payload) {
  if (!payload || typeof payload !== 'object') throw new TypeError('A recovery scan request is required.');
  validateTarget(payload.target);
  const params = payload.params;
  if (!params || typeof params !== 'object' || Array.isArray(params)) throw new TypeError('Select an unallocated range to scan.');
  integer(params.offset, 'Scan offset', MIB);
  integer(params.length, 'Scan length', 512);
  if (params.offset % 512 || params.length % 512 || !Number.isSafeInteger(params.offset + params.length)) throw new TypeError('The scan range must be sector aligned and inside the disk.');
  if (params.deepScan != null && typeof params.deepScan !== 'boolean') throw new TypeError('Deep scan must be true or false.');
  const disk = expectedDisk(payload);
  if (disk && !freeExtents(disk).some((gap) => params.offset >= gap.offset && params.offset + params.length <= gap.offset + gap.length)) throw new TypeError('Scan only the current unallocated space.');
  return payload;
}

function validateCandidate(candidate) {
  if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) throw new TypeError('Choose a detected lost volume.');
  integer(candidate.offset, 'Candidate offset', MIB);
  integer(candidate.size, 'Candidate size', MIB);
  if (![512, 1024, 2048, 4096].includes(candidate.bytesPerSector)) throw new TypeError('Unsupported candidate sector size.');
  if (candidate.offset % candidate.bytesPerSector || candidate.size % candidate.bytesPerSector || !Number.isSafeInteger(candidate.offset + candidate.size)) throw new TypeError('Candidate geometry is not sector aligned.');
  if (!FILE_SYSTEMS.has(candidate.fileSystem)) throw new TypeError('The detected file system is unsupported.');
  if (candidate.recoverable === false) throw new TypeError('This candidate has no verified backup boot sector or file-system metadata.');
  if (typeof candidate.bootHash !== 'string' || !/^[a-f0-9]{64}$/i.test(candidate.bootHash)) throw new TypeError('The candidate boot-sector fingerprint is missing. Run the scan again.');
  return candidate;
}

function validateRecoveryPayload(payload) {
  if (!payload || typeof payload !== 'object') throw new TypeError('A recovery request is required.');
  validateTarget(payload.target);
  const candidate = validateCandidate(payload.params?.candidate);
  const letter = payload.params.driveLetter ?? '';
  if (typeof letter !== 'string' || !/^[A-Z]?$/.test(letter)) throw new TypeError('Choose a drive letter from A to Z, or no drive letter.');
  const disk = expectedDisk(payload, true);
  if (disk.isBoot || disk.isSystem || disk.partitions?.some((partition) => partition.isBoot || partition.isSystem)) throw new TypeError('Volume recovery cannot edit a Windows boot or system disk.');
  if (disk.isOffline || disk.isReadOnly) throw new TypeError('The recovery disk must be online and writable.');
  if (!['GPT', 'MBR'].includes(disk.partitionStyle)) throw new TypeError('Recovery requires an existing GPT or MBR partition table.');
  if (disk.partitionStyle === 'MBR' && candidate.offset + candidate.size > 2 * 1024 ** 4) throw new TypeError('The recovered MBR volume would exceed 2 TiB.');
  if (!freeExtents(disk, candidate.bytesPerSector).some((gap) => candidate.offset >= gap.offset && candidate.offset + candidate.size <= gap.offset + gap.length)) throw new TypeError('The detected volume overlaps a current partition or disk metadata.');
  if (letter && payload.expectedSnapshot.disks.some((entry) => entry.partitions?.some((partition) => partition.driveLetter === letter))) throw new TypeError(`Drive letter ${letter}: is already in use.`);
  return payload;
}

async function invoke(action, payload, onProgress, signal) {
  if (process.platform !== 'win32') throw new Error('Volume recovery requires Windows.');
  if (signal?.aborted) return { success: action === 'scan', cancelled: true, candidates: [], scannedBytes: 0, totalBytes: payload.params.length, message: action === 'scan' ? 'Recovery scan cancelled.' : 'Volume recovery cancelled before any partition changes.' };
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'partly20-recovery-'));
  const requestPath = path.join(directory, 'request.json');
  const cancelPath = path.join(directory, 'cancel.flag');
  const cancel = () => { fs.writeFile(cancelPath, '', { flag: 'w' }).catch(() => {}); };
  try {
    await fs.writeFile(requestPath, JSON.stringify(payload), { encoding: 'utf8', flag: 'wx' });
    signal?.addEventListener('abort', cancel, { once: true });
    if (signal?.aborted) cancel();
    return await new Promise((resolve, reject) => {
      const child = spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Action', action, '-PayloadPath', requestPath, '-CancelPath', cancelPath], { windowsHide: true, shell: false, stdio: ['ignore', 'pipe', 'pipe'],env:windowsPowerShellEnv() });
      let stdout = '', stderr = '', buffer = '';
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => {
        stderr = (stderr + chunk).slice(-65536);
        buffer += chunk;
        const lines = buffer.split(/\r?\n/); buffer = lines.pop();
        for (const line of lines) {
          if (!line.startsWith('PARTLY20_RECOVERY:')) continue;
          try { onProgress?.(JSON.parse(line.slice('PARTLY20_RECOVERY:'.length))); } catch { /* Progress consumers cannot interrupt native disk work. */ }
        }
      });
      child.once('error', reject);
      child.once('close', (code) => {
        let result;
        try { result = JSON.parse(stdout.replace(/^\uFEFF/, '').trim()); } catch { reject(new Error(`The recovery service did not return a result${code ? ` (exit ${code})` : ''}. ${stderr.replace(/^PARTLY20_RECOVERY:.*$/gm, '').trim().slice(0, 400)}`)); return; }
        if (result.error) {
          const error = new Error(result.error.message || 'Volume recovery failed.');
          error.result = result;
          error.code = result.error.code;
          if (result.createdPartitionNumber) error.createdPartitionNumber = result.createdPartitionNumber;
          reject(error);
        } else resolve(result);
      });
    });
  } finally {
    signal?.removeEventListener('abort', cancel);
    await fs.rm(directory, { recursive: true, force: true });
  }
}

async function scanLostVolumes(payload, onProgress, signal) { validateScanPayload(payload); return invoke('scan', payload, onProgress, signal); }
async function recoverVolume(payload, onProgress, signal) {
  validateRecoveryPayload(payload);
  if (recovering) throw new Error('Another volume recovery is already running.');
  recovering = true;
  try { return await invoke('recover', payload, onProgress, signal); } finally { recovering = false; }
}

module.exports = { scanLostVolumes, recoverVolume, validateScanPayload, validateRecoveryPayload, validateCandidate, validateTarget, freeExtents };
