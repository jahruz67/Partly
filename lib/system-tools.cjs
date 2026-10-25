'use strict';

const { spawn } = require('node:child_process');
const { existsSync } = require('node:fs');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const {windowsPowerShellEnv}=require('./windows-env.cjs');
const { randomUUID } = require('node:crypto');
const scriptResource = process.resourcesPath && path.join(process.resourcesPath, 'windows', 'system-tools.ps1');
const SCRIPT = scriptResource && existsSync(scriptResource) ? scriptResource : path.resolve(__dirname, '../windows/system-tools.ps1');
const ACTIONS = new Set(['capabilities', 'backup', 'listBackups', 'restore', 'migrate', 'downloadDisk2vhd', 'recoveryMedia', 'findOperatingSystems', 'copyOperatingSystem']);
const READ_ACTIONS = new Set(['capabilities', 'listBackups', 'findOperatingSystems']);
let running = false;

function drive(value, name = 'Drive') {
  if (typeof value !== 'string' || !/^[A-Z]:?\\?$/i.test(value)) throw new TypeError(`${name} must be a Windows drive letter.`);
  return value[0].toUpperCase();
}
function absolutePath(value, name = 'Path', extension) {
  if (typeof value !== 'string' || value.length > 32700 || !path.win32.isAbsolute(value) || /[\u0000-\u001f"<>|]/.test(value) || /^\\\\[.?]\\/.test(value)) throw new TypeError(`${name} must be an absolute local or network file path.`);
  if (extension && !extension.test(path.win32.extname(value))) throw new TypeError(`${name} has an unsupported file extension.`);
  return value;
}
function target(value, partition = true) {
  if (!value || !Number.isSafeInteger(value.diskNumber) || value.diskNumber < 0 || typeof value.diskUniqueId !== 'string' || !value.diskUniqueId.trim() || value.diskUniqueId.length > 512) throw new TypeError('A persistent destination disk identity is required.');
  if (partition && (!Number.isSafeInteger(value.partitionNumber) || value.partitionNumber < 1 || !Number.isSafeInteger(value.partitionOffset) || value.partitionOffset < 0)) throw new TypeError('An exact destination partition is required.');
}
function backupTarget(value) {
  if (typeof value !== 'string' || (!/^[A-Z]:\\?$/i.test(value) && !/^\\\\[^\\/]+\\[^\\/]+(?:\\[^\u0000-\u001f"<>|]*)?$/.test(value))) throw new TypeError('Choose a backup drive root, such as F:, or a network share.');
}
function validateRequest(action, payload = {}) {
  if (!ACTIONS.has(action)) throw new TypeError('Unsupported system tool.');
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new TypeError('Invalid system tool request.');
  if (action === 'backup') {
    if (payload.mode === 'wim') { drive(payload.sourceDrive, 'Source drive'); absolutePath(payload.imagePath, 'Backup image', /^\.wim$/i); }
    else {
      if (!Array.isArray(payload.sourceDrives) || !payload.sourceDrives.length || payload.sourceDrives.length > 24) throw new TypeError('Choose at least one source volume.');
      payload.sourceDrives.forEach((value) => drive(value, 'Source drive'));
      backupTarget(payload.destination);
      if (payload.includeSystem != null && typeof payload.includeSystem !== 'boolean') throw new TypeError('Include system volumes must be true or false.');
      if (/^[A-Z]:\\?$/i.test(payload.destination) && payload.sourceDrives.some((value) => drive(value) === drive(payload.destination))) throw new TypeError('The backup destination cannot also be a source volume.');
    }
  } else if (action === 'listBackups') {
    if (payload.destination) absolutePath(/^[A-Z]:$/i.test(payload.destination) ? payload.destination + '\\' : payload.destination, 'Backup location');
  } else if (action === 'restore') {
    target(payload.target); drive(payload.destinationDrive, 'Destination drive');
    if (payload.index != null && (!Number.isSafeInteger(payload.index) || payload.index < 1 || payload.index > 65535)) throw new TypeError('Choose a positive WIM image index.');
    if (payload.imagePath) absolutePath(payload.imagePath, 'Backup image', /^\.wim$/i);
    else {
      if (typeof payload.version !== 'string' || !/^\d{2}\/\d{2}\/\d{4}-\d{2}:\d{2}$/.test(payload.version)) throw new TypeError('Choose a valid backup version.');
      drive(payload.sourceDrive, 'Original drive'); backupTarget(payload.backupTarget);
      if (payload.machine && (typeof payload.machine !== 'string' || !/^[A-Za-z0-9_.-]{1,63}$/.test(payload.machine))) throw new TypeError('Invalid backup computer name.');
    }
  } else if (action === 'migrate') {
    absolutePath(payload.destinationPath, 'Destination virtual disk', /^\.(vhd|vhdx|vmdk|vdi|qcow2)$/i);
    if (payload.inputPath) {
      absolutePath(payload.inputPath, 'Source virtual disk', /^\.(vhd|vhdx|vmdk|vdi|qcow2|img|raw)$/i);
      if (path.win32.normalize(payload.inputPath).toLowerCase() === path.win32.normalize(payload.destinationPath).toLowerCase()) throw new TypeError('Source and destination must be different files.');
      if (payload.format && !['vhd', 'vhdx', 'vmdk', 'vdi', 'qcow2'].includes(payload.format)) throw new TypeError('Unsupported destination virtual disk format.');
      if (payload.allocation && !['Dynamic', 'Fixed'].includes(payload.allocation)) throw new TypeError('Choose Dynamic or Fixed allocation.');
    } else {
      if (!Array.isArray(payload.sourceDrives) || !payload.sourceDrives.length) throw new TypeError('Choose source volumes or an existing virtual disk.');
      payload.sourceDrives.forEach((value) => drive(value));
      if (payload.acceptEula !== true) throw new TypeError('Read and accept the Microsoft Sysinternals license before running Disk2vhd.');
      if (payload.toolPath) absolutePath(payload.toolPath, 'Disk2vhd executable', /^\.exe$/i);
      if (!/\.vhdx?$/i.test(payload.destinationPath)) throw new TypeError('Physical-to-virtual export creates VHD or VHDX files.');
    }
  } else if (action === 'downloadDisk2vhd') {
    if (payload.acceptDownload !== true) throw new TypeError('Confirm downloading Disk2vhd from Microsoft first.');
    if (payload.destination) absolutePath(payload.destination, 'Tool installation folder');
  } else if (action === 'recoveryMedia') {
    if (!['native', 'iso', 'usb'].includes(payload.kind)) throw new TypeError('Choose Windows recovery USB, WinPE ISO, or WinPE USB.');
    if (payload.kind === 'iso') absolutePath(payload.destination, 'Recovery ISO', /^\.iso$/i);
    if (payload.kind === 'usb') { drive(payload.destination, 'USB drive'); target(payload.target, false); }
    if (payload.architecture && !['amd64', 'arm64'].includes(payload.architecture)) throw new TypeError('Choose amd64 or arm64.');
    if (payload.bootex != null && typeof payload.bootex !== 'boolean') throw new TypeError('UEFI 2023 signing option must be true or false.');
  } else if (action === 'copyOperatingSystem') {
    drive(payload.sourceDrive, 'Windows source drive'); target(payload.destinationDisk, false);
    absolutePath(payload.stagingDirectory, 'Image staging folder');
    if (!payload.expectedSnapshot || !Array.isArray(payload.expectedSnapshot.disks)) throw new TypeError('A fresh disk snapshot is required.');
  }
  return payload;
}

async function execute(action, payload = {}, options = {}) {
  validateRequest(action, payload);
  if (process.platform !== 'win32') throw new Error('Windows system tools require Windows.');
  const mutating = !READ_ACTIONS.has(action);
  if (mutating && running) throw new Error('Another system tool is already running.');
  if (options.signal?.aborted) return { success: false, cancelled: true, message: 'Cancelled before starting.' };
  if (mutating) running = true;
  let folder;
  try { folder = await fs.mkdtemp(path.join(os.tmpdir(), 'partly20-tools-')); }
  catch (error) { if (mutating) running = false; throw error; }
  const requestFile = path.join(folder, 'request.json');
  const cancelFile = path.join(folder, 'cancel.flag');
  const abort = () => { fs.writeFile(cancelFile, 'cancel', 'utf8').catch(() => {}); };
  options.signal?.addEventListener('abort', abort, { once: true });
  try {
    await fs.writeFile(requestFile, JSON.stringify(payload), { flag: 'wx', encoding: 'utf8' });
    return await new Promise((resolve, reject) => {
      const child = spawn(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Action', action, '-PayloadPath', requestFile, '-CancelPath', cancelFile], { windowsHide: true, shell: false, stdio: ['ignore', 'pipe', 'pipe'],env:windowsPowerShellEnv() });
      let stdout = '', stderr = '', buffer = '';
      child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => {
        stderr = (stderr + chunk).slice(-65536); buffer += chunk;
        const lines = buffer.split(/\r?\n/); buffer = lines.pop();
        for (const line of lines) if (line.startsWith('PARTLY20_PROGRESS:')) {
          try { options.onProgress?.(JSON.parse(line.slice(18))); } catch { /* Progress consumers cannot stop storage processes. */ }
        }
      });
      child.once('error', reject);
      child.once('close', (code) => {
        let result;
        try { result = JSON.parse(stdout.replace(/^\uFEFF/, '').trim()); } catch { reject(new Error('Windows system tool returned an invalid response. ' + stderr.slice(-1200))); return; }
        if (result.error && !result.cancelled) { const error = new Error(result.error.message || result.error); error.result = result; reject(error); }
        else if (code && !result.cancelled) reject(new Error(result.message || 'The system tool did not complete.'));
        else resolve(result);
      });
    });
  } finally {
    options.signal?.removeEventListener('abort', abort);
    await fs.rm(folder, { force: true, recursive: true });
    if (mutating) running = false;
  }
}

const call = (action) => (payload = {}, onProgress, signal) => execute(action, payload, { onProgress, signal });
function prepareBackupRequest(payload = {}) {
  if (payload.mode !== 'wim' || payload.imagePath) return payload;
  absolutePath(payload.destination, 'Backup destination folder');
  const letter = drive(payload.sourceDrive, 'Source drive');
  return { ...payload, imagePath: path.win32.join(payload.destination, `Partly20-${letter}-${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 8)}.wim`) };
}
module.exports = { validateRequest, prepareBackupRequest, execute, getCapabilities: () => execute('capabilities'), backup: (payload, onProgress, signal) => execute('backup', prepareBackupRequest(payload), { onProgress, signal }), listBackups: call('listBackups'), restore: call('restore'), migrate: call('migrate'), downloadDisk2vhd: call('downloadDisk2vhd'), installDisk2vhd: call('downloadDisk2vhd'), createRecoveryMedia: call('recoveryMedia'), findOperatingSystems: () => execute('findOperatingSystems'), copyOperatingSystem: call('copyOperatingSystem') };
