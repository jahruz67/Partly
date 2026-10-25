'use strict';

// These tests validate request boundaries only. They never invoke PowerShell or disk commands.
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateOperations, validateQueue, validateTarget } = require('../lib/storage-service.cjs');

const target = { diskNumber: 7, diskUniqueId: 'test-disk-id', partitionNumber: 2, partitionOffset: 1048576 };
const operation = (type, params = {}) => ({ id: 'op-1', type, ...target, params });
const request = (...operations) => ({ operations, expectedSnapshot: { disks: [] } });

test('requires persistent disk identity and exact partition location', () => {
  assert.doesNotThrow(() => validateTarget(target));
  assert.throws(() => validateTarget({ ...target, diskUniqueId: '' }), /identity/);
  assert.throws(() => validateTarget({ ...target, partitionOffset: -1 }), /offset/);
  assert.throws(() => validateTarget({ ...target, partitionNumber: 0 }), /number/);
});

test('rejects unsupported and ambiguous operations before invoking Windows', () => {
  assert.throws(() => validateOperations(request(operation('wipe'))), /Unsupported/);
  assert.throws(() => validateOperations(request(operation('delete'), operation('delete'))), /unique/);
  assert.throws(() => validateOperations({ operations: [operation('delete')] }), /snapshot/);
  assert.throws(() => validateOperations(request()), /Queue/);
});

test('validates safe byte sizes and filesystem choices', () => {
  assert.doesNotThrow(() => validateOperations(request(operation('create', { offset: 1048576, size: 104857600, fileSystem: 'NTFS', label: 'Work', driveLetter: 'F' }))));
  assert.throws(() => validateOperations(request(operation('resize', { size: Number.MAX_SAFE_INTEGER + 1 }))), /size/);
  assert.throws(() => validateOperations(request(operation('format', { fileSystem: 'EXT4' }))), /Choose NTFS/);
  assert.throws(() => validateOperations(request(operation('initialize', { partitionStyle: 'MBR' }))), /GPT/);
});

test('rejects unsafe labels, invalid drive letters, and nonboolean hidden states', () => {
  assert.throws(() => validateOperations(request(operation('label', { label: 'bad/name' }))), /label/);
  assert.throws(() => validateOperations(request(operation('letter', { driveLetter: 'bad' }))), /A to Z/);
  assert.doesNotThrow(() => validateOperations(request(operation('letter', { driveLetter: '' }))));
  assert.doesNotThrow(() => validateOperations(request(operation('letter', { driveLetter: 'A' }))));
  assert.throws(() => validateOperations(request(operation('hide', { hidden: 'false' }))), /true or false/);
  assert.doesNotThrow(() => validateOperations(request(operation('hide', { hidden: false }))));
});

const MIB = 1024 ** 2;
const GIB = 1024 ** 3;
const diskSnapshot = () => ({ disks: [{ number: 7, uniqueId: 'test-disk-id', size: 64 * GIB, partitionStyle: 'GPT', partitions: [{ diskNumber: 7, partitionNumber: 2, offset: MIB, size: 40 * GIB, sizeRemaining: 30 * GIB, driveLetter: 'D', fileSystem: 'NTFS', type: 'Basic' }] }] });
const queuedRequest = (...operations) => ({ operations, expectedSnapshot: diskSnapshot() });
const createOperation = (params = {}) => ({ id: 'op-create', type: 'create', diskNumber: 7, diskUniqueId: 'test-disk-id', params: { offset: MIB, size: 40 * GIB, fileSystem: 'NTFS', label: 'Data', driveLetter: 'D', ...params } });

test('dry queue preflight permits deleting D and reusing its space and drive letter', async () => {
  await assert.doesNotReject(validateQueue(queuedRequest(operation('delete'), createOperation())));
});

test('dry queue preflight rejects a later invalid create before any operation can execute', async () => {
  await assert.rejects(validateQueue(queuedRequest(operation('delete'), createOperation({ size: 80 * GIB }))), /fit entirely/);
  await assert.rejects(validateQueue(queuedRequest(operation('delete'), createOperation({ fileSystem: 'FAT32' }))), /32 GB/);
  await assert.rejects(validateQueue(queuedRequest(operation('delete'), createOperation({ fileSystem: 'exFAT', label: 'A'.repeat(16) }))), /15 characters/);
});

test('dry queue preflight accounts for an earlier letter removal', async () => {
  await assert.doesNotReject(validateQueue(queuedRequest(operation('letter', { driveLetter: '' }), createOperation({ offset: 41 * GIB, size: 10 * GIB }))));
  await assert.rejects(validateQueue(queuedRequest(createOperation({ offset: 41 * GIB, size: 10 * GIB }))), /already in use/);
});

test('dry queue preflight allows RAW initialization followed by creation', async () => {
  const raw = diskSnapshot();
  raw.disks[0].partitionStyle = 'RAW';
  raw.disks[0].partitions = [];
  await assert.doesNotReject(validateQueue({ expectedSnapshot: raw, operations: [operation('initialize', { partitionStyle: 'GPT' }), createOperation()] }));
});
