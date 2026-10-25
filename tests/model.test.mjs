import test from 'node:test';
import assert from 'node:assert/strict';
import { MIB, GIB, formatBytes, escapeHtml, getSegments, projectInventory, validateOperation, describeOperation } from '../src/model.js';
import { createPreviewBridge } from '../src/preview.js';

const fixture = () => ({ disks: [
  { number: 0, uniqueId: 'disk-system', size: 100 * GIB, partitionStyle: 'GPT', partitions: [
    { diskNumber: 0, partitionNumber: 1, offset: MIB, size: 50 * GIB, driveLetter: 'C', label: 'Windows', fileSystem: 'NTFS', isBoot: true, sizeRemaining: 30 * GIB },
  ] },
  { number: 1, uniqueId: 'disk-usb', size: 64 * GIB, partitionStyle: 'GPT', partitions: [
    { diskNumber: 1, partitionNumber: 1, offset: MIB, size: 32 * GIB, driveLetter: 'D', label: 'USB', fileSystem: 'NTFS', sizeRemaining: 24 * GIB },
  ] },
] });
const operation = (type, params = {}) => ({ id: 'test', type, diskNumber: 1, diskUniqueId: 'disk-usb', partitionNumber: 1, partitionOffset: MIB, params, targetLabel: 'USB (D:)' });

test('formats capacities and escapes untrusted volume labels', () => {
  assert.equal(formatBytes(8 * GIB), '8 GB');
  assert.equal(formatBytes(NaN), '—');
  assert.equal(escapeHtml('<img onerror="x">&\''), '&lt;img onerror=&quot;x&quot;&gt;&amp;&#39;');
});

test('free extents are aligned and exclude leading and trailing metadata', () => {
  const segments = getSegments(fixture().disks[1]);
  assert.equal(segments[0].key, 'd1-p1');
  assert.equal(segments[1].offset, 32 * GIB + MIB);
  assert.equal(segments[1].size, 32 * GIB - 2 * MIB);
  assert.equal(segments[1].key, `d1-free-${32 * GIB + MIB}`);
  assert.equal(segments[1].size % MIB, 0);
});

test('free-space model handles unordered physical partitions and tiny alignment gaps', () => {
  const disk = { number: 2, size: 10 * GIB, partitions: [
    { partitionNumber: 2, offset: 5 * GIB, size: GIB },
    { partitionNumber: 1, offset: MIB, size: 2 * GIB },
  ] };
  const segments = getSegments(disk);
  assert.deepEqual(segments.map((item) => item.unallocated), [false, true, false, true]);
  for (let i = 1; i < segments.length; i++) assert.ok(segments[i].offset >= segments[i - 1].offset + segments[i - 1].size);
  assert.equal(getSegments({ number: 1, size: 8 * MIB, partitions: [{ partitionNumber: 1, offset: MIB, size: 6 * MIB }] }).length, 1);
});

test('delete then create projects the complete video workflow without mutating source inventory', () => {
  const inventory = fixture();
  const original = JSON.stringify(inventory);
  const deletion = operation('delete');
  const creation = operation('create', { offset: MIB, size: 60 * GIB, driveLetter: 'F', label: 'New Volume', fileSystem: 'NTFS' });
  assert.equal(validateOperation(deletion, inventory), null);
  assert.equal(validateOperation(creation, inventory, [deletion]), null);
  const projected = projectInventory(inventory, [deletion, creation]);
  assert.equal(projected.disks[1].partitions.length, 1);
  assert.equal(projected.disks[1].partitions[0].partitionNumber, -1);
  assert.equal(projected.disks[1].partitions[0].driveLetter, 'F');
  assert.equal(projected.disks[1].partitions[0].isPending, true);
  assert.equal(JSON.stringify(inventory), original);
});

test('rejects stale disk identity and protected system partitions', () => {
  assert.match(validateOperation({ ...operation('delete'), diskUniqueId: 'wrong' }, fixture()), /identity/);
  assert.match(validateOperation({ ...operation('delete'), diskNumber: 0, diskUniqueId: 'disk-system' }, fixture()), /protected/);
  const protectedInventory = fixture();
  protectedInventory.disks[1].partitions[0].gptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}';
  assert.match(validateOperation(operation('format', { fileSystem: 'NTFS', label: 'A' }), protectedInventory), /protected/);
});

test('blocks overlapping create and edits targeting an already deleted partition', () => {
  const creation = operation('create', { offset: MIB, size: 8 * GIB, driveLetter: 'E', label: 'Test', fileSystem: 'NTFS' });
  assert.match(validateOperation(creation, fixture()), /unallocated/);
  assert.match(validateOperation(operation('label', { label: 'Changed' }), fixture(), [operation('delete')]), /deletion/);
});

test('validates resize boundaries, stored data and integer aligned sizes', () => {
  assert.equal(validateOperation(operation('resize', { size: 40 * GIB }), fixture()), null);
  assert.match(validateOperation(operation('resize', { size: 4 * GIB }), fixture()), /data stored/);
  assert.match(validateOperation(operation('resize', { size: 80 * GIB }), fixture()), /adjacent/);
  assert.match(validateOperation(operation('resize', { size: GIB + 1 }), fixture()), /aligned/);
  assert.match(validateOperation(operation('resize', { size: Infinity }), fixture()), /aligned/);
});

test('drive-letter conflicts include pending creates and releases from deletions', () => {
  assert.match(validateOperation(operation('letter', { driveLetter: 'C' }), fixture()), /already in use/);
  const create = operation('create', { offset: 32 * GIB + MIB, size: 8 * GIB, driveLetter: 'E', label: 'Test', fileSystem: 'NTFS' });
  assert.equal(validateOperation(create, fixture()), null);
  assert.match(validateOperation(operation('letter', { driveLetter: 'E' }), fixture(), [create]), /already in use/);
  assert.equal(validateOperation(operation('letter', { driveLetter: '' }), fixture()), null);
});

test('file system and label restrictions mirror Windows format limits', () => {
  assert.match(validateOperation(operation('format', { fileSystem: 'ext4', label: 'USB' }), fixture()), /Choose/);
  assert.match(validateOperation(operation('format', { fileSystem: 'exFAT', label: 'A'.repeat(16) }), fixture()), /15 characters/);
  assert.match(validateOperation(operation('label', { label: 'Bad|Name' }), fixture()), /unsupported/);
  const bigger = fixture(); bigger.disks[1].partitions[0].size = 40 * GIB;
  assert.match(validateOperation(operation('format', { fileSystem: 'FAT32', label: 'USB' }), bigger), /32 GB/);
});

test('initialization is limited to empty RAW disks and GPT', () => {
  const inventory = fixture(); inventory.disks[1].partitionStyle = 'RAW'; inventory.disks[1].partitions = [];
  assert.equal(validateOperation(operation('initialize', { partitionStyle: 'GPT' }), inventory), null);
  assert.match(validateOperation(operation('initialize', { partitionStyle: 'GPT' }), fixture()), /empty/);
  assert.match(validateOperation(operation('initialize', { partitionStyle: 'MBR' }), inventory), /GPT/);
});

test('projection retains used bytes across a resize and changes labels and letters in sequence', () => {
  const projected = projectInventory(fixture(), [operation('resize', { size: 40 * GIB }), operation('label', { label: 'Work' }), operation('letter', { driveLetter: 'F' })]);
  const partition = projected.disks[1].partitions[0];
  assert.equal(partition.sizeRemaining, 32 * GIB);
  assert.equal(partition.label, 'Work');
  assert.equal(partition.driveLetter, 'F');
  assert.equal(describeOperation(operation('resize', { size: 40 * GIB })), 'Resize USB (D:) to 40 GB');
});

test('reference preview has integral non-overlapping disk geometry', async () => {
  const inventory = await createPreviewBridge().inventory();
  for (const disk of inventory.disks) {
    assert.equal(disk.size % MIB, 0);
    let previousEnd = MIB;
    for (const partition of disk.partitions) {
      assert.ok(Number.isSafeInteger(partition.offset));
      assert.ok(Number.isSafeInteger(partition.size));
      assert.equal(partition.offset % MIB, 0);
      assert.equal(partition.size % MIB, 0);
      assert.ok(partition.offset >= previousEnd);
      previousEnd = partition.offset + partition.size;
      assert.ok(previousEnd <= disk.size - MIB);
    }
  }
});

test('reference delete/create queue supports undo and redo without stale geometry', async () => {
  const inventory = await createPreviewBridge().inventory();
  const disk = inventory.disks[1];
  const partition = disk.partitions[0];
  const deletion = { id: 'delete-preview', type: 'delete', diskNumber: disk.number, diskUniqueId: disk.uniqueId,
    partitionNumber: partition.partitionNumber, partitionOffset: partition.offset, params: {} };
  const queue = [deletion], redo = [];
  const free = getSegments(projectInventory(inventory, queue).disks[1]).find((segment) => segment.unallocated);
  const creation = { id: 'create-preview', type: 'create', diskNumber: disk.number, diskUniqueId: disk.uniqueId,
    params: { offset: free.offset, size: free.size, driveLetter: 'F', label: 'New Volume', fileSystem: 'NTFS' } };
  assert.equal(validateOperation(creation, inventory, queue), null);
  queue.push(creation);
  const completedProjection = projectInventory(inventory, queue);
  redo.push(queue.pop());
  redo.push(queue.pop());
  assert.deepEqual(projectInventory(inventory, queue), inventory);
  while (redo.length) {
    const entry = redo.at(-1);
    assert.equal(validateOperation(entry, inventory, queue), null);
    queue.push(redo.pop());
  }
  assert.deepEqual(projectInventory(inventory, queue), completedProjection);
  assert.equal(completedProjection.disks[1].partitions[0].driveLetter, 'F');
});
