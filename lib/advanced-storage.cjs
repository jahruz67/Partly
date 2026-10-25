'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const { existsSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {windowsPowerShellEnv}=require('./windows-env.cjs');

const ACTIONS = new Set(['surface', 'sectors', 'writeSectors', 'move', 'copy', 'convert']);
const ALIASES = { surfaceScan: 'surface', readSectors: 'sectors', movePartition: 'move', copyVolume: 'copy', convertFileSystem: 'convert', 'write-sectors': 'writeSectors' };
const WRITE_ACTIONS = new Set(['writeSectors', 'move', 'copy', 'convert']);
const MIB = 1024 ** 2;
const resource = process.resourcesPath && path.join(process.resourcesPath, 'windows', 'advanced-storage.ps1');
const SCRIPT = resource && existsSync(resource) ? resource : path.resolve(__dirname, '../windows/advanced-storage.ps1');
let writing = false;

function integer(value, name, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new TypeError(`${name} is outside its supported integer range.`);
}
function target(value, partition = false) {
  if (!value || typeof value !== 'object') throw new TypeError('Select a disk or partition.');
  integer(value.diskNumber, 'Disk number');
  if (typeof value.diskUniqueId !== 'string' || !value.diskUniqueId.trim() || value.diskUniqueId.length > 512) throw new TypeError('A persistent disk identity is required.');
  if (partition || value.partitionNumber != null) {
    integer(value.partitionNumber, 'Partition number', 1);
    integer(value.partitionOffset, 'Partition offset');
  }
}
function directory(value, name) {
  if (typeof value !== 'string' || !path.win32.isAbsolute(value) || /^\\\\/.test(value) || value.includes('\0')) throw new TypeError(`${name} must be an absolute local folder path.`);
}
function hex(value, name) {
  if (typeof value !== 'string' || !/^(?:[\da-f]{2})+$/i.test(value) || value.length > 2 * 128 * 4096) throw new TypeError(`${name} must contain complete hexadecimal bytes, up to 128 sectors.`);
}
function validateRequest(action, payload) {
  action = ALIASES[action] || action;
  if (!ACTIONS.has(action)) throw new TypeError('Unsupported advanced storage action.');
  if (!payload || typeof payload !== 'object') throw new TypeError('An operation request is required.');
  target(payload.target, WRITE_ACTIONS.has(action));
  const p = payload.params || {};
  if (typeof p !== 'object' || Array.isArray(p)) throw new TypeError('Invalid operation parameters.');
  if (WRITE_ACTIONS.has(action) && (!payload.expectedSnapshot || !Array.isArray(payload.expectedSnapshot.disks))) throw new TypeError('The original disk snapshot is required for writes.');
  if (action === 'surface') {
    if (p.offset != null) integer(p.offset, 'Scan offset');
    if (p.length != null) integer(p.length, 'Scan length', 1);
  }
  if (action === 'sectors' || action === 'writeSectors') {
    integer(p.sector, 'Sector offset');
    if (action === 'sectors') integer(p.count ?? 1, 'Sector count', 1, 128);
    else {
      hex(p.originalHex, 'Original sector data'); hex(p.newHex, 'New sector data');
      if (p.originalHex.length !== p.newHex.length) throw new TypeError('Original and replacement sector data must have equal lengths.');
      directory(p.backupDirectory, 'Backup folder');
    }
  }
  if (action === 'move') {
    integer(p.offset, 'New partition offset', MIB);
    if (p.offset % MIB) throw new TypeError('The new partition offset must be aligned to 1 MiB.');
    directory(p.stagingDirectory, 'Staging folder');
  }
  if (action === 'copy') {
    target(p.destination);
    integer(p.destination.offset, 'Destination offset', MIB);
    integer(p.destination.size, 'Destination size', MIB);
    if (p.destination.offset % MIB || p.destination.size % 512) throw new TypeError('Destination offset must be aligned to 1 MiB and capacity to a complete disk sector.');
    if (p.destination.driveLetter != null && !/^[A-Z]?$/.test(p.destination.driveLetter)) throw new TypeError('Choose an available drive letter.');
  }
  if (action === 'convert') {
    if(!['NTFS','FAT32','exFAT'].includes(p.fileSystem))throw new TypeError('Choose NTFS, FAT32, or exFAT.');
    if(p.fileSystem!=='NTFS'||p.stagingDirectory)directory(p.stagingDirectory,'Conversion staging folder');
    if(p.allowMetadataChanges!=null&&typeof p.allowMetadataChanges!=='boolean')throw new TypeError('Confirm metadata changes explicitly.');
  }
  return payload;
}

async function execute(action, payload, { onProgress, signal } = {}) {
  action = ALIASES[action] || action;
  validateRequest(action, payload);
  if (process.platform !== 'win32') throw new Error('These operations require Windows.');
  if (WRITE_ACTIONS.has(action) && writing) throw new Error('Another advanced disk operation is already running.');
  if (signal?.aborted) return { success: false, cancelled: true, message: 'Operation cancelled before starting.' };
  const isWrite = WRITE_ACTIONS.has(action);
  if (isWrite) writing = true;
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'partly20-advanced-'));
  const payloadPath = path.join(temp, 'request.json');
  const cancelPath = path.join(temp, 'cancel');
  const recoveryRoot = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'Partly 20', 'recovery');
  const cancellation = () => { fs.writeFile(cancelPath, 'cancel', 'utf8').catch(() => {}); };
  try {
    await fs.mkdir(recoveryRoot, { recursive: true });
    await fs.writeFile(payloadPath, JSON.stringify({ ...payload, recoveryRoot, requestId: crypto.randomUUID() }), { encoding: 'utf8', flag: 'wx' });
    signal?.addEventListener('abort', cancellation, { once: true });
    return await new Promise((resolve, reject) => {
      const executable = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      const child = spawn(executable, ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Action', action, '-PayloadPath', payloadPath, '-CancellationFile', cancelPath], { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],env:windowsPowerShellEnv() });
      let stdout = '', stderr = '', progress = '';
      child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => {
        stderr = (stderr + chunk).slice(-32768);
        progress += chunk;
        const lines = progress.split(/\r?\n/); progress = lines.pop();
        for (const line of lines) if (line.startsWith('PARTLY20_PROGRESS:')) {
          try { onProgress?.(JSON.parse(line.slice('PARTLY20_PROGRESS:'.length))); } catch { /* Progress observers cannot terminate a storage write. */ }
        }
      });
      child.once('error', reject);
      child.once('close', (code) => {
        let result;
        try { result = JSON.parse(stdout.replace(/^\uFEFF/, '').trim()); }
        catch { reject(new Error(`Advanced storage returned no readable result (exit ${code}). ${stderr.replace(/^PARTLY20_PROGRESS:.*$/gm, '').trim().slice(-1000)}`)); return; }
        // Write failures preserve recovery details and must remain visible, rather than becoming a generic IPC error.
        if (result.error && !isWrite) { const error = new Error(result.error.message || result.error); error.result = result; reject(error); }
        else resolve(result);
      });
    });
  } finally {
    signal?.removeEventListener('abort', cancellation);
    await fs.rm(temp, { recursive: true, force: true });
    if (isWrite) writing = false;
  }
}

const surfaceScan = (payload, onProgress, signal) => execute('surface', payload, { onProgress, signal });
const readSectors = (payload) => execute('sectors', payload);
const writeSectors = (payload, onProgress) => execute('writeSectors', payload, { onProgress });
const movePartition = (payload, onProgress, signal) => execute('move', payload, { onProgress, signal });
const copyVolume = (payload, onProgress, signal) => execute('copy', payload, { onProgress, signal });
const convertFileSystem = (payload, onProgress) => execute('convert', payload, { onProgress });

module.exports = { execute, surfaceScan, readSectors, writeSectors, movePartition, copyVolume, convertFileSystem, validateRequest };
