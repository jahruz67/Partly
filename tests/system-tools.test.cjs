'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateRequest, prepareBackupRequest } = require('../lib/system-tools.cjs');
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const path=require('node:path');
const {windowsPowerShellEnv}=require('../lib/windows-env.cjs');
const disk = { diskNumber: 9, diskUniqueId: 'disposable-test-disk', partitionNumber: 2, partitionOffset: 1048576 };

test('backup boundaries reject same-volume storage and invalid destinations', () => {
  assert.doesNotThrow(() => validateRequest('backup', { sourceDrives: ['D'], destination: 'F:', includeSystem: false }));
  assert.throws(() => validateRequest('backup', { sourceDrives: ['D'], destination: 'D:' }), /cannot also/);
  assert.throws(() => validateRequest('backup', { sourceDrives: [], destination: 'F:' }), /at least/);
  assert.throws(() => validateRequest('backup', { sourceDrives: ['D'], destination: 'relative' }), /drive root/);
});
test('WIM backups use explicit new image paths and known source volumes', () => {
  assert.doesNotThrow(() => validateRequest('backup', { mode: 'wim', sourceDrive: 'D:', imagePath: 'F:\\Backups\\data.wim' }));
  assert.throws(() => validateRequest('backup', { mode: 'wim', sourceDrive: '*', imagePath: 'F:\\data.wim' }), /drive letter/);
  assert.throws(() => validateRequest('backup', { mode: 'wim', sourceDrive: 'D', imagePath: '\\\\.\\PhysicalDrive0' }), /absolute/);
});
test('restore requires persistent exact target identity before any Windows invocation', () => {
  assert.doesNotThrow(() => validateRequest('restore', { target: disk, destinationDrive: 'F', imagePath: 'G:\\data.wim' }));
  assert.throws(() => validateRequest('restore', { target: { ...disk, diskUniqueId: '' }, destinationDrive: 'F', imagePath: 'G:\\data.wim' }), /identity/);
  assert.throws(() => validateRequest('restore', { target: { ...disk, partitionOffset: -1 }, destinationDrive: 'F', imagePath: 'G:\\data.wim' }), /partition/);
  assert.throws(() => validateRequest('restore', { target: disk, destinationDrive: 'F', version: 'latest', sourceDrive: 'D', backupTarget: 'G:' }), /version/);
});
test('V2V conversion preserves source image and validates output formats', () => {
  assert.doesNotThrow(() => validateRequest('migrate', { inputPath: 'F:\\old.vmdk', destinationPath: 'G:\\new.vhdx', format: 'vhdx', allocation: 'Dynamic' }));
  assert.throws(() => validateRequest('migrate', { inputPath: 'F:\\old.vhd', destinationPath: 'f:\\old.vhd' }), /different/);
  assert.throws(() => validateRequest('migrate', { inputPath: 'F:\\old.vhd', destinationPath: 'G:\\new.exe' }), /extension/);
});
test('Microsoft tool download and execution each require their explicit user choice', () => {
  assert.throws(() => validateRequest('downloadDisk2vhd', {}), /Confirm downloading/);
  assert.doesNotThrow(() => validateRequest('downloadDisk2vhd', { acceptDownload: true }));
  assert.throws(() => validateRequest('migrate', { sourceDrives: ['C'], destinationPath: 'F:\\snapshot.vhd' }), /license/);
  assert.doesNotThrow(() => validateRequest('migrate', { sourceDrives: ['C'], destinationPath: 'F:\\snapshot.vhd', acceptEula: true }));
});
test('recovery media USB requires exact non-system target, ISO only requires a file', () => {
  assert.doesNotThrow(() => validateRequest('recoveryMedia', { kind: 'native' }));
  assert.doesNotThrow(() => validateRequest('recoveryMedia', { kind: 'iso', destination: 'F:\\Recovery.iso', architecture: 'amd64' }));
  assert.throws(() => validateRequest('recoveryMedia', { kind: 'usb', destination: 'F:' }), /identity/);
  assert.doesNotThrow(() => validateRequest('recoveryMedia', { kind: 'usb', destination: 'F:', target: disk }));
});
test('OS copy requires original disk snapshot and image staging path', () => {
  assert.throws(() => validateRequest('copyOperatingSystem', { sourceDrive: 'C', destinationDisk: disk, stagingDirectory: 'F:\\Backups' }), /snapshot/);
  assert.doesNotThrow(() => validateRequest('copyOperatingSystem', { sourceDrive: 'C', destinationDisk: disk, stagingDirectory: 'F:\\Backups', expectedSnapshot: { disks: [] } }));
});
test('folder-based WIM form generates a unique image path inside the selected folder', () => {
  const first = prepareBackupRequest({ mode: 'wim', sourceDrive: 'D', destination: 'F:\\Backups' });
  const second = prepareBackupRequest({ mode: 'wim', sourceDrive: 'D', destination: 'F:\\Backups' });
  assert.match(first.imagePath, /^F:\\Backups\\Partly20-D-.*\.wim$/);
  assert.notEqual(first.imagePath, second.imagePath);
  assert.doesNotThrow(() => validateRequest('backup', first));
});
test('multi-image restore index and disk-only USB target are validated', () => {
  assert.doesNotThrow(() => validateRequest('restore', { target: disk, destinationDrive: 'F', imagePath: 'G:\\data.wim', index: 3 }));
  assert.throws(() => validateRequest('restore', { target: disk, destinationDrive: 'F', imagePath: 'G:\\data.wim', index: 0 }), /index/);
  assert.doesNotThrow(() => validateRequest('recoveryMedia', { kind: 'usb', destination: 'F', target: { diskNumber: 9, diskUniqueId: 'id' } }));
});

test('ADK batch invocation preserves standard Windows installation paths and blocks command expansion',{skip:process.platform!=='win32'},async()=>{
  const report=await promisify(execFile)(path.join(process.env.SystemRoot||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe'),['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(__dirname,'adk-command-fixtures.ps1')],{env:windowsPowerShellEnv(),timeout:60000});
  const result=JSON.parse(report.stdout.trim());assert.equal(result.success,true);assert.equal(result.spacesAndParenthesesVerified,true);assert.equal(result.commandExpansionBlocked,true);assert.equal(result.installedAdkRun,false);assert.equal(result.diskChanged,false);
});
