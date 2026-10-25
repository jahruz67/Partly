'use strict';
// Every backend below is an in-memory fake. These tests never launch a process,
// open a disk, or invoke a Windows storage command.
const test = require('node:test');
const assert = require('node:assert/strict');
const { executeBatch, assertFresh, diskFingerprint } = require('../lib/batch-service.cjs');
const MIB = 1024 ** 2;
const copy = (value) => structuredClone(value);

function inventory() {
  return { isAdmin: true, disks: [
    { number: 7, uniqueId: 'batch-source', serialNumber: 'TEST-7', size: 128 * MIB, partitionStyle: 'GPT', partitions: [
      { diskNumber: 7, partitionNumber: 1, offset: MIB, size: 32 * MIB, sizeRemaining: 20 * MIB, label: 'Data', driveLetter: 'D', fileSystem: 'NTFS', type: 'Basic' },
      { diskNumber: 7, partitionNumber: 2, offset: 80 * MIB, size: 16 * MIB, sizeRemaining: 8 * MIB, label: 'Archive', driveLetter: 'E', fileSystem: 'FAT32', type: 'Basic' }
    ] },
    { number: 8, uniqueId: 'batch-destination', serialNumber: 'TEST-8', size: 128 * MIB, partitionStyle: 'GPT', partitions: [] }
  ] };
}
function op(id, type, params = {}, partitionNumber = 1) {
  return { id, type, diskNumber: 7, diskUniqueId: 'batch-source', partitionNumber, partitionOffset: partitionNumber === 1 ? MIB : 80 * MIB, targetLabel: partitionNumber === 1 ? 'Data (D:)' : 'Archive (E:)', params };
}
function copyOperation(id = 'copy') {
  return op(id, 'copy', { destination: { diskNumber: 8, diskUniqueId: 'batch-destination', offset: MIB, size: 32 * MIB, driveLetter: 'F', label: 'Data copy', fileSystem: 'NTFS' } });
}
function backend(initial = inventory()) {
  let current = copy(initial), getCount = 0;
  const calls = [], progress = [];
  function edit(operation) {
    const disk = current.disks.find((entry) => entry.number === operation.diskNumber);
    const partition = disk.partitions.find((entry) => entry.partitionNumber === operation.partitionNumber);
    if (operation.type === 'label') partition.label = operation.params.label;
    else if (operation.type === 'letter') partition.driveLetter = operation.params.driveLetter;
    else if (operation.type === 'move') partition.offset = operation.params.offset;
    else if (operation.type === 'convert') partition.fileSystem = operation.params.fileSystem;
    else if (operation.type === 'copy') {
      const destination = operation.params.destination;
      current.disks.find((entry) => entry.number === destination.diskNumber).partitions.push({ ...copy(partition), diskNumber: destination.diskNumber, partitionNumber: 1, offset: destination.offset, driveLetter: destination.driveLetter, label: destination.label });
    } else throw new Error('Unexpected fake operation: ' + operation.type);
  }
  const storage = {
    async getInventory() { getCount++; return copy(current); },
    async applyOperations(payload, onProgress, signal) {
      assert.equal(payload.operations.length, 1, 'normal storage executes a single operation at a safe batch boundary');
      assert.deepEqual(payload.expectedSnapshot, current, 'normal backend receives the latest real layout');
      const operation = payload.operations[0];
      calls.push({ backend: 'storage', type: operation.type, operation: copy(operation), snapshot: copy(payload.expectedSnapshot), signal });
      onProgress?.({ percent: 50, message: 'Applying ' + operation.type });
      edit(operation);
      return { success: true, inventory: copy(current), message: 'Applied ' + operation.type };
    }
  };
  const advanced = {
    async execute(action, payload, options) {
      assert.deepEqual(payload.expectedSnapshot, current, 'advanced backend receives the latest real layout');
      calls.push({ backend: 'advanced', action, operation: copy(payload.target), snapshot: copy(payload.expectedSnapshot), signal: options.signal });
      options.onProgress?.({ percent: 50, message: 'Applying ' + action, cancellable: false });
      edit(payload.target);
      return { success: true, inventory: copy(current), message: 'Applied ' + action };
    }
  };
  return { storage, advanced, calls, progress, onProgress: (event) => progress.push(event), getCount: () => getCount, current: () => copy(current), setCurrent: (next) => { current = copy(next); }, edit };
}

test('mixed batch routes normal/copy/move/conversion operations sequentially with fresh snapshots', async () => {
  const expectedSnapshot = inventory(), dependencies = backend(expectedSnapshot), controller = new AbortController();
  const operations = [op('rename', 'label', { label: 'Work' }), copyOperation(), op('move', 'move', { offset: 40 * MIB, stagingDirectory: 'C:\\disposable-test-stage' }), op('convert', 'convert', { fileSystem: 'NTFS' }, 2)];
  const result = await executeBatch({ expectedSnapshot, operations }, { ...dependencies, signal: controller.signal });
  assert.equal(result.success, true);
  assert.deepEqual(dependencies.calls.map((entry) => entry.backend === 'storage' ? 'storage:' + entry.type : 'advanced:' + entry.action), ['storage:label', 'advanced:copyVolume', 'advanced:movePartition', 'advanced:convertFileSystem']);
  assert.equal(dependencies.calls[1].snapshot.disks[0].partitions[0].label, 'Work');
  assert.equal(dependencies.calls[2].snapshot.disks[1].partitions[0].driveLetter, 'F');
  assert.equal(dependencies.calls[3].snapshot.disks[0].partitions[0].offset, 40 * MIB);
  assert.deepEqual(result.completed.map((entry) => entry.id), ['rename', 'copy', 'move', 'convert']);
  assert.equal(result.inventory.disks[0].partitions[1].fileSystem, 'NTFS');
  assert.deepEqual(dependencies.progress.filter((entry) => entry.state === 'completed').map((entry) => entry.percent), [25, 50, 75, 100]);
  assert.equal(dependencies.progress.find((entry) => entry.id === 'copy' && entry.message)?.percent, 37.5);
  assert.ok(dependencies.calls.every((entry) => entry.signal === controller.signal));
  assert.deepEqual(expectedSnapshot, inventory(), 'the original snapshot remains unchanged');
});

test('a changed source identity, partition geometry, or drive letter rejects before any disk operation', async () => {
  for (const change of [
    (disk) => { disk.uniqueId = 'replacement-device'; },
    (disk) => { disk.partitions[0].offset += MIB; },
    (disk) => { disk.partitions[0].size -= MIB; },
    (disk) => { disk.partitions[0].driveLetter = 'J'; }
  ]) {
    const expectedSnapshot = inventory(), actual = inventory(); change(actual.disks[0]);
    const dependencies = backend(actual);
    await assert.rejects(executeBatch({ expectedSnapshot, operations: [op('rename', 'label', { label: 'Work' })] }, dependencies), /changed after the queue/);
    assert.equal(dependencies.calls.length, 0);
  }
});

test('copy destination freshness is checked in addition to the source disk', async () => {
  const expectedSnapshot = inventory(), actual = inventory(); actual.disks[1].serialNumber = 'REPLACED';
  const dependencies = backend(actual);
  await assert.rejects(executeBatch({ expectedSnapshot, operations: [copyOperation()] }, dependencies), /Disk 8 changed/);
  assert.equal(dependencies.calls.length, 0);
});

test('preflight rejects a later invalid queue entry before earlier valid edits can start', async () => {
  const dependencies = backend(), expectedSnapshot = inventory();
  await assert.rejects(executeBatch({ expectedSnapshot, operations: [op('rename', 'label', { label: 'Work' }), op('letter', 'letter', { driveLetter: 'E' })] }, dependencies), /Operation 2:.*already in use/);
  assert.equal(dependencies.calls.length, 0);
  assert.equal(dependencies.getCount(), 0, 'the complete queue is checked before invoking a backend');
  await assert.rejects(executeBatch({ expectedSnapshot, operations: [op('duplicate', 'label', { label: 'Work' }), op('duplicate', 'letter', { driveLetter: 'G' })] }, dependencies), /unique/);
});

test('cancellation before execution leaves every planned disk operation untouched', async () => {
  const dependencies = backend(), controller = new AbortController(); controller.abort();
  const result = await executeBatch({ expectedSnapshot: inventory(), operations: [op('rename', 'label', { label: 'Work' }), copyOperation()] }, { ...dependencies, signal: controller.signal });
  assert.equal(result.cancelled, true);
  assert.equal(result.success, false);
  assert.equal(result.completed.length, 0);
  assert.equal(dependencies.calls.length, 0);
  assert.deepEqual(dependencies.current(), inventory());
});

test('cancellation at a completed operation boundary preserves that operation and skips the next', async () => {
  const dependencies = backend(), controller = new AbortController();
  const result = await executeBatch({ expectedSnapshot: inventory(), operations: [op('rename', 'label', { label: 'Work' }), copyOperation()] }, { ...dependencies, signal: controller.signal, onProgress(event) { dependencies.progress.push(event); if (event.state === 'completed') controller.abort(); } });
  assert.equal(result.cancelled, true);
  assert.deepEqual(result.completed.map((entry) => entry.id), ['rename']);
  assert.equal(dependencies.calls.length, 1);
  assert.equal(result.inventory.disks[0].partitions[0].label, 'Work');
  assert.equal(result.inventory.disks[1].partitions.length, 0);
});

test('cancellation during an unsafe advanced step waits for its safe completion boundary', async () => {
  const dependencies = backend(), controller = new AbortController();
  const result = await executeBatch({ expectedSnapshot: inventory(), operations: [copyOperation(), op('rename', 'label', { label: 'Work' })] }, { ...dependencies, signal: controller.signal, onProgress(event) { dependencies.progress.push(event); if (event.cancellable === false) controller.abort(); } });
  assert.equal(result.cancelled, true);
  assert.deepEqual(result.completed.map((entry) => entry.id), ['copy']);
  assert.equal(dependencies.calls.length, 1);
  assert.equal(result.inventory.disks[1].partitions[0].driveLetter, 'F');
  assert.equal(result.inventory.disks[0].partitions[0].label, 'Data');
});

test('a structured backend failure retains prior successes and skips remaining writes', async () => {
  const dependencies = backend();
  dependencies.advanced.execute = async (action, payload) => {
    dependencies.calls.push({ backend: 'advanced', action });
    return { success: false, completed: [{ id: 'copy-stage', status: 'completed' }], failedOperation: { id: 'copy', status: 'failed' }, error: { message: 'Verification failed' }, inventory: payload.expectedSnapshot };
  };
  const result = await executeBatch({ expectedSnapshot: inventory(), operations: [op('rename', 'label', { label: 'Work' }), copyOperation(), op('letter', 'letter', { driveLetter: 'G' })] }, dependencies);
  assert.equal(result.success, false);
  assert.deepEqual(result.completed.map((entry) => entry.id), ['rename', 'copy-stage']);
  assert.equal(result.failedOperation.id, 'copy');
  assert.equal(result.error.message, 'Verification failed');
  assert.equal(dependencies.calls.length, 2);
});

test('an exception returns the current disk inventory and a failed operation without replaying earlier edits', async () => {
  const dependencies = backend();
  dependencies.advanced.execute = async () => { throw new Error('Mock native verification error'); };
  const result = await executeBatch({ expectedSnapshot: inventory(), operations: [op('rename', 'label', { label: 'Work' }), copyOperation()] }, dependencies);
  assert.equal(result.success, false);
  assert.equal(result.error.message, 'Mock native verification error');
  assert.equal(result.failedOperation.id, 'copy');
  assert.deepEqual(result.completed.map((entry) => entry.id), ['rename']);
  assert.equal(result.inventory.disks[0].partitions[0].label, 'Work');
  assert.equal(dependencies.calls.length, 1);
});

test('fingerprints ignore partition enumeration order and freshness ignores unrelated disks', () => {
  const before = inventory(), after = inventory(); after.disks[0].partitions.reverse();
  assert.equal(diskFingerprint(before.disks[0]), diskFingerprint(after.disks[0]));
  after.disks[1].size += MIB;
  assert.doesNotThrow(() => assertFresh(before, after, [op('rename', 'label', { label: 'Work' })]));
});

test('administrator rights are rechecked against the current inventory before execution', async () => {
  const actual = inventory(); actual.isAdmin = false; const dependencies = backend(actual);
  await assert.rejects(executeBatch({ expectedSnapshot: inventory(), operations: [op('rename', 'label', { label: 'Work' })] }, dependencies), /administrator/);
  assert.equal(dependencies.calls.length, 0);
});
