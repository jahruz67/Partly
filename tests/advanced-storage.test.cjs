'use strict';
// Request-boundary tests only. These never open devices, invoke PowerShell, or write disk sectors.
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateRequest } = require('../lib/advanced-storage.cjs');
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const path=require('node:path');
const {windowsPowerShellEnv}=require('../lib/windows-env.cjs');
const target = { diskNumber: 8, diskUniqueId: 'test-physical-id', partitionNumber: 2, partitionOffset: 1048576 };
const payload = (params = {}) => ({ target, params, expectedSnapshot: { disks: [] } });

test('advanced reads require disk identity and bounded sector counts', () => {
  assert.doesNotThrow(() => validateRequest('sectors', payload({ sector: 0, count: 128 })));
  assert.doesNotThrow(() => validateRequest('readSectors', payload({ sector: 0, count: 128 })));
  assert.doesNotThrow(() => validateRequest('surfaceScan', payload()));
  assert.throws(() => validateRequest('sectors', payload({ sector: 0, count: 129 })), /Sector count/);
  assert.throws(() => validateRequest('surface', { target: { diskNumber: 1 }, params: {} }), /identity/);
  assert.throws(() => validateRequest('sectors', payload({ sector: -1 })), /Sector offset/);
});
test('advanced writes require snapshot and existing partition identities', () => {
  assert.throws(() => validateRequest('convert', { target, params: { fileSystem: 'NTFS' } }), /snapshot/);
  assert.throws(() => validateRequest('move', { ...payload({ offset: 2 ** 22, stagingDirectory: 'C:\\Stage' }), target: { diskNumber: 1, diskUniqueId: 'id' } }), /Partition number/);
  assert.throws(() => validateRequest('move', payload({ offset: 1048577, stagingDirectory: 'C:\\Stage' })), /aligned/);
});
test('sector edits preserve byte count and require a local backup directory', () => {
  const p = { sector: 1, originalHex: '00'.repeat(512), newHex: 'ff'.repeat(512), backupDirectory: 'C:\\Backups' };
  assert.doesNotThrow(() => validateRequest('writeSectors', payload(p)));
  assert.throws(() => validateRequest('writeSectors', payload({ ...p, newHex: 'ff' })), /equal lengths/);
  assert.throws(() => validateRequest('writeSectors', payload({ ...p, newHex: 'zz'.repeat(512) })), /hexadecimal/);
  assert.throws(() => validateRequest('writeSectors', payload({ ...p, backupDirectory: '\\\\server\\share' })), /local folder/);
  assert.throws(() => validateRequest('writeSectors', payload({ ...p, backupDirectory: '..\\backup' })), /absolute/);
});
test('copy geometry and conversion choices are checked before Windows is invoked', () => {
  const destination = { diskNumber: 9, diskUniqueId: 'destination-id', offset: 1048576, size: 1024 ** 3, driveLetter: 'T' };
  assert.doesNotThrow(() => validateRequest('copy', payload({ destination })));
  assert.doesNotThrow(() => validateRequest('copy', payload({ destination: { ...destination, size: destination.size + 512 } })));
  assert.throws(() => validateRequest('copy', payload({ destination: { ...destination, offset: 2 } })), /Destination offset/);
  assert.throws(() => validateRequest('copy', payload({ destination: { ...destination, driveLetter: 'C:' } })), /drive letter/);
  assert.throws(() => validateRequest('convert', payload({ fileSystem: 'exFAT' })), /staging folder/);
  assert.doesNotThrow(() => validateRequest('convert', payload({ fileSystem: 'exFAT',stagingDirectory:'C:\\Conversion-stage',allowMetadataChanges:true })));
  assert.throws(() => validateRequest('convert', payload({ fileSystem: 'ReFS' })), /Choose NTFS/);
  assert.doesNotThrow(() => validateRequest('convert', payload({ fileSystem: 'NTFS' })));
  assert.doesNotThrow(() => validateRequest('convertFileSystem', payload({ fileSystem: 'NTFS' })));
});

test('staged conversion file fixtures verify content, empty folders, tampering, and alternate streams',{skip:process.platform!=='win32'},async()=>{
  const result=await promisify(execFile)(path.join(process.env.SystemRoot||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe'),['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'conversion-file-fixtures.ps1')],{env:windowsPowerShellEnv(),timeout:60000});
  const report=JSON.parse(result.stdout.trim());assert.equal(report.success,true);assert.equal(report.tamperingRejected,true);assert.equal(report.alternateStreamsRejected,true);assert.equal(report.emptyDirectoriesPreserved,true);assert.equal(report.diskDeviceOpened,false);
});
