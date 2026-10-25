'use strict';

const { spawn } = require('node:child_process');
const { existsSync } = require('node:fs');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {windowsPowerShellEnv}=require('./windows-env.cjs');

// extraResources keeps the script outside app.asar, where native PowerShell can read it.
const resourceScript = process.resourcesPath && path.join(process.resourcesPath, 'windows', 'storage.ps1');
const SCRIPT = resourceScript && existsSync(resourceScript) ? resourceScript : path.resolve(__dirname, '../windows/storage.ps1');
const OPERATION_TYPES = new Set(['create', 'resize', 'format', 'delete', 'letter', 'label', 'hide', 'initialize']);
let applying = false;

function integer(value, name, min = 0) {
  if (!Number.isSafeInteger(value) || value < min) throw new TypeError(`${name} must be a whole number of bytes or a valid disk/partition number.`);
}

function validateTarget(target, partition = true) {
  if (!target || typeof target !== 'object') throw new TypeError('A storage target is required.');
  integer(target.diskNumber, 'Disk number');
  if (typeof target.diskUniqueId !== 'string' || !target.diskUniqueId.trim() || target.diskUniqueId.length > 512) throw new TypeError('The disk identity is required. Refresh the disk list.');
  if (partition) {
    integer(target.partitionNumber, 'Partition number', 1);
    integer(target.partitionOffset, 'Partition offset');
  }
}

function validateOperations(payload) {
  if (!payload || !Array.isArray(payload.operations) || !payload.operations.length || payload.operations.length > 100) throw new TypeError('Queue between 1 and 100 operations.');
  if (!payload.expectedSnapshot || !Array.isArray(payload.expectedSnapshot.disks)) throw new TypeError('A fresh disk snapshot is required.');
  const ids = new Set();
  for (const op of payload.operations) {
    if (!op || !OPERATION_TYPES.has(op.type)) throw new TypeError('Unsupported storage operation.');
    if (typeof op.id !== 'string' || !op.id || op.id.length > 128 || ids.has(op.id)) throw new TypeError('Every operation must have a unique ID.');
    ids.add(op.id);
    validateTarget(op, !['create', 'initialize'].includes(op.type));
    if (op.params != null && (typeof op.params !== 'object' || Array.isArray(op.params))) throw new TypeError('Invalid operation parameters.');
    const p = op.params || {};
    if (['resize', 'create'].includes(op.type)) integer(p.size, 'Partition size', 1024 * 1024);
    if (op.type === 'create') integer(p.offset, 'Partition offset', 1024 * 1024);
    if (['format', 'create'].includes(op.type) && !['NTFS', 'exFAT', 'FAT32'].includes(p.fileSystem)) throw new TypeError('Choose NTFS, exFAT, or FAT32.');
    if (['letter', 'create'].includes(op.type) && p.driveLetter != null && (typeof p.driveLetter !== 'string' || !/^[A-Z]?$/.test(p.driveLetter))) throw new TypeError('Choose a drive letter from A to Z, or no drive letter.');
    if (op.type === 'letter' && typeof p.driveLetter !== 'string') throw new TypeError('Choose a drive letter from A to Z, or no drive letter.');
    if (['label', 'create', 'format'].includes(op.type) && p.label != null && (typeof p.label !== 'string' || p.label.length > 32 || /[\\/:*?"<>|\x00-\x1f]/.test(p.label))) throw new TypeError('Use a label of at most 32 characters without Windows filename punctuation.');
    if (op.type === 'hide' && typeof p.hidden !== 'boolean') throw new TypeError('Hidden state must be true or false.');
    if (op.type === 'initialize' && p.partitionStyle !== 'GPT') throw new TypeError('Only GPT initialization is supported.');
  }
  return payload;
}

async function validateQueue(payload) {
  validateOperations(payload);
  const { validateOperation } = await import('../src/model.js');
  const previous = [];
  for (const operation of payload.operations) {
    const error = validateOperation(operation, payload.expectedSnapshot, previous);
    if (error) throw new Error(`Operation ${previous.length + 1}: ${error}`);
    const disk = payload.expectedSnapshot.disks.find((item) => item.number === operation.diskNumber);
    if (operation.type === 'create' && String(disk.partitionStyle).toUpperCase() === 'MBR' && operation.params.offset + operation.params.size > 2 * 1024 ** 4) throw new Error('MBR partitions cannot extend past 2 TiB.');
    previous.push(operation);
  }
  return payload;
}

async function invoke(action, payload, onProgress, signal) {
  if (process.platform !== 'win32') throw new Error('Real disk management requires Windows.');
  const systemRoot = process.env.SystemRoot || 'C:\\Windows';
  const executable = path.join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'partly20-storage-'));
  const payloadPath = path.join(directory, 'request.json');
  const cancelPath = path.join(directory, 'cancel');
  const requestCancel = () => { fs.writeFile(cancelPath, 'cancel', 'utf8').catch(() => {}); };
  try {
    await fs.writeFile(payloadPath, JSON.stringify({ ...(payload || {}), cancelPath }), { encoding: 'utf8', flag: 'wx' });
    if (signal?.aborted) requestCancel();
    signal?.addEventListener('abort', requestCancel, { once: true });
    return await new Promise((resolve, reject) => {
      const child = spawn(executable, ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Action', action, '-PayloadPath', payloadPath], {
        windowsHide: true,
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: windowsPowerShellEnv(),
      });
      let stdout = '';
      let stderr = '';
      let progressBuffer = '';
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; if (stdout.length > 8 * 1024 * 1024) child.kill(); });
      child.stderr.on('data', (chunk) => {
        stderr += chunk;
        progressBuffer += chunk;
        const lines = progressBuffer.split(/\r?\n/);
        progressBuffer = lines.pop();
        for (const line of lines) {
          if (!line.startsWith('PARTLY20_PROGRESS:')) continue;
          try { if (onProgress) onProgress(JSON.parse(line.slice('PARTLY20_PROGRESS:'.length))); } catch { /* Consumer callbacks cannot interrupt a disk command. */ }
        }
      });
      child.once('error', reject);
      child.once('close', (code) => {
        let result;
        try { result = JSON.parse(stdout.replace(/^\uFEFF/, '').trim()); } catch {
          reject(new Error(`Windows storage service did not return a valid result${code ? ` (exit ${code})` : ''}. ${stderr.replace(/^PARTLY20_PROGRESS:.*$/gm, '').trim().slice(0, 500)}`));
          return;
        }
        // Apply failures return completed steps and must remain reviewable by the renderer.
        if (result.error && action !== 'apply') {
          const error = new Error(result.error.message || result.error);
          error.code = result.error.code || 'STORAGE_ERROR';
          reject(error);
        } else resolve(result);
      });
    });
  } finally {
    signal?.removeEventListener('abort', requestCancel);
    await fs.rm(directory, { recursive: true, force: true });
  }
}

async function getInventory() { return invoke('inventory'); }
async function getPartitionLimits(target) { validateTarget(target); return invoke('limits', { target }); }
async function checkPartition(target,signal) { validateTarget(target); return invoke('check', { target },undefined,signal); }
async function applyOperations(payload, onProgress, signal) {
  // Validate the entire projected queue before Windows can run even its first write.
  await validateQueue(payload);
  if (applying) throw new Error('Another storage operation is already running.');
  applying = true;
  try { return await invoke('apply', payload, onProgress, signal); } finally { applying = false; }
}
async function exportDiagnostics() {
  return { app: 'Partly 20', platform: process.platform, windowsRelease: os.release(), collectedAt: new Date().toISOString(), inventory: await getInventory() };
}

module.exports = { getInventory, getPartitionLimits, applyOperations, checkPartition, exportDiagnostics, validateOperations, validateQueue, validateTarget };
