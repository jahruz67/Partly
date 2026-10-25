'use strict';
function diskFingerprint(disk) {
  return JSON.stringify({ number: disk.number, id: String(disk.uniqueId).trim(), serial: String(disk.serialNumber || '').trim(), size: disk.size, style: disk.partitionStyle,
    partitions: [...disk.partitions].sort((a,b) => a.offset-b.offset).map((p) => [p.partitionNumber,p.offset,p.size,p.driveLetter || '',p.label || '',p.fileSystem || '']) });
}
function assertFresh(expected, actual, operations) {
  const touched = new Set(operations.flatMap((operation) => [operation.diskNumber, ...(operation.params?.destination ? [operation.params.destination.diskNumber] : [])]));
  for (const number of touched) {
    const before = expected.disks.find((disk) => disk.number === number), current = actual.disks.find((disk) => disk.number === number);
    if (!before || !current || diskFingerprint(before) !== diskFingerprint(current)) throw new Error(`Disk ${number} changed after the queue was prepared. Refresh and plan the changes again.`);
  }
}
async function executeBatch(payload, { storage, advanced, onProgress = () => {}, signal }) {
  const { validateOperation } = await import('../src/model.js');
  if (!payload || !Array.isArray(payload.operations) || !payload.operations.length || payload.operations.length > 100 || !Array.isArray(payload.expectedSnapshot?.disks)) throw new Error('A valid operation queue and original disk inventory are required.');
  const ids = new Set(), previous = [];
  for (const operation of payload.operations) {
    if (typeof operation.id !== 'string' || !operation.id || ids.has(operation.id)) throw new Error('Queue entries need unique operation identifiers.');
    const error = validateOperation(operation, payload.expectedSnapshot, previous);
    if (error) throw new Error(`Operation ${previous.length + 1}: ${error}`);
    ids.add(operation.id); previous.push(operation);
  }
  let current = await storage.getInventory();
  assertFresh(payload.expectedSnapshot, current, payload.operations);
  if (!current.isAdmin) throw new Error('Run Partly 20 as administrator to apply disk changes.');
  const completed = [];
  for (let index = 0; index < payload.operations.length; index++) {
    const originalOperation = payload.operations[index];
    const operation = { ...originalOperation };
    if (!['create','initialize'].includes(operation.type)) {
      const disk=current.disks.find(item=>item.number===operation.diskNumber);
      const target=disk?.partitions.find(partition=>partition.offset===operation.partitionOffset);
      if(!target)return {success:false,completed,failedOperation:{...operation,status:'failed',error:'The target partition no longer exists at its reviewed position.'},inventory:current,error:{message:'The target partition changed before execution.'}};
      operation.partitionNumber=target.partitionNumber;
    }
    if (signal?.aborted) return { success: false, cancelled: true, completed, inventory: current, message: 'Cancelled before the next operation. Completed changes were preserved.' };
    onProgress({ id: operation.id, state: 'running', index, total: payload.operations.length, type: operation.type, percent: index / payload.operations.length * 100, cancellable: true });
    try {
      let result;
      const progress = (event) => onProgress({ ...event, id: operation.id, type: operation.type, index, total: payload.operations.length, percent: (index + Math.min(100, Math.max(0, event.percent || 0)) / 100) / payload.operations.length * 100 });
      if (['move','copy','convert'].includes(operation.type)) {
        const action = { move: 'movePartition', copy: 'copyVolume', convert: 'convertFileSystem' }[operation.type];
        result = await advanced.execute(action, { target: operation, params: operation.params, expectedSnapshot: current }, { onProgress: progress, signal });
      } else result = await storage.applyOperations({ operations: [operation], expectedSnapshot: current }, progress, signal);
      if (result.success === false) return { ...result, completed: [...completed,...(result.completed || [])], failedOperation: result.failedOperation || {...operation,status:result.cancelled?'cancelled':'failed',error:result.error?.message||result.message||'Operation stopped.'} };
      const {inventory:resultInventory,...retainedResult}=result;
      completed.push({ ...operation, status: 'completed', message: result.message,result:retainedResult });
      current = result.inventory || await storage.getInventory();
      onProgress({ id: operation.id, state: 'completed', index: index + 1, total: payload.operations.length, type: operation.type, percent: (index + 1) / payload.operations.length * 100, cancellable: true });
    } catch (error) {
      return { success: false, completed, failedOperation: { ...operation, status: 'failed', error: error.message }, error: { message: error.message }, inventory: await storage.getInventory().catch(() => current) };
    }
  }
  return { success: true, completed, inventory: current, message: 'All queued changes completed successfully.' };
}
module.exports = { executeBatch, assertFresh, diskFingerprint };
