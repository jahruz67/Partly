/** Pure disk geometry and queue model shared by the desktop UI and tests. */
export const MIB = 1024 ** 2;
export const GIB = 1024 ** 3;

const SUPPORTED_OPERATIONS = new Set(['create', 'resize', 'format', 'delete', 'letter', 'label', 'hide', 'initialize', 'move', 'copy', 'convert']);
const FILE_SYSTEMS = new Set(['NTFS', 'exFAT', 'FAT32']);
const PROTECTED_GPT_TYPES = new Set([
  'c12a7328-f81f-11d2-ba4b-00a0c93ec93b', // EFI System
  'e3c9e316-0b5c-4db8-817d-f92df00215ae', // Microsoft Reserved
  'de94bba4-06d1-4d40-a16a-bfd50179d6ac', // Windows Recovery
]);

const clone = (value) => JSON.parse(JSON.stringify(value));
const alignedUp = (value) => Math.ceil(value / MIB) * MIB;
const alignedDown = (value) => Math.floor(value / MIB) * MIB;
const integerBytes = (value) => Number.isSafeInteger(value) && value >= 0;
const normalizeId = (value) => String(value ?? '').trim().toLowerCase();

export function formatBytes(bytes, precision = 2) {
  if (!Number.isFinite(Number(bytes)) || Number(bytes) < 0) return '—';
  const value = Number(bytes);
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let unit = 0;
  let scaled = value;
  while (scaled >= 1024 && unit < units.length - 1) {
    scaled /= 1024;
    unit += 1;
  }
  return `${scaled.toLocaleString('en-US', { maximumFractionDigits: unit ? precision : 0 })} ${units[unit]}`;
}

export function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

/** Return physical partitions and usable free extents in ascending offset order. */
export function getSegments(disk) {
  const partitions = [...(disk.partitions ?? [])].sort((a, b) => a.offset - b.offset);
  const segments = [];
  // Keep the conventional leading alignment area and trailing GPT metadata clear.
  let cursor = MIB;
  const usableEnd = alignedDown(Math.max(0, Number(disk.size) - MIB));
  const appendFree = (start, end) => {
    const offset = alignedUp(Math.max(MIB, start));
    const size = alignedDown(Math.min(end, usableEnd) - offset);
    if (size > MIB) {
      segments.push({ key: `d${disk.number}-free-${offset}`, diskNumber: disk.number,
        offset, size, label: 'Unallocated', unallocated: true });
    }
  };
  for (const partition of partitions) {
    appendFree(cursor, partition.offset);
    segments.push({ ...partition, key: `d${disk.number}-p${partition.partitionNumber}`, unallocated: false });
    cursor = Math.max(cursor, Number(partition.offset) + Number(partition.size));
  }
  appendFree(cursor, usableEnd);
  return segments;
}

function findPartition(disk, operation) {
  return disk.partitions.find((partition) =>
    partition.partitionNumber === operation.partitionNumber &&
    partition.offset === operation.partitionOffset);
}

/** Project queued edits without mutating inventory returned by Windows. */
export function projectInventory(snapshot, operations = []) {
  const projected = clone(snapshot);
  let createdNumber = -1;
  for (const operation of operations) {
    const disk = projected.disks?.find((item) => item.number === operation.diskNumber);
    if (!disk) continue;
    const params = operation.params ?? {};
    disk.partitions ??= [];
    if (operation.type === 'initialize') {
      disk.partitionStyle = params.partitionStyle ?? 'GPT';
      disk.isPending = true;
      continue;
    }
    if (operation.type === 'create') {
      disk.partitions.push({ diskNumber: disk.number, partitionNumber: createdNumber--,
        offset: params.offset, size: params.size, driveLetter: params.driveLetter ?? '',
        label: params.label ?? 'New Volume', fileSystem: params.fileSystem ?? 'NTFS',
        sizeRemaining: params.size, isBoot: false, isSystem: false, isHidden: false,
        isReadOnly: false, isProtected: false, type: 'Basic', isPending: true,
        pendingOperationId: operation.id });
      continue;
    }
    const partition = findPartition(disk, operation);
    if (!partition) continue;
    if (operation.type === 'copy') {
      const destination = params.destination;
      const destinationDisk = projected.disks.find((item) => item.number === destination?.diskNumber);
      if (destinationDisk) destinationDisk.partitions.push({ ...clone(partition), diskNumber: destinationDisk.number, partitionNumber: createdNumber--, offset: destination.offset, size: partition.size, driveLetter: destination.driveLetter || '', label: destination.label || partition.label, isPending: true, pendingOperationId: operation.id });
      continue;
    }
    partition.isPending = true;
    switch (operation.type) {
      case 'resize': {
        const used = Math.max(0, partition.size - (partition.sizeRemaining ?? partition.size));
        partition.size = params.size;
        partition.sizeRemaining = Math.max(0, params.size - used);
        break;
      }
      case 'format':
        partition.fileSystem = params.fileSystem;
        partition.label = params.label ?? '';
        partition.sizeRemaining = partition.size;
        break;
      case 'delete':
        disk.partitions = disk.partitions.filter((item) => item !== partition);
        break;
      case 'letter': partition.driveLetter = params.driveLetter ?? ''; break;
      case 'label': partition.label = params.label ?? ''; break;
      case 'hide': partition.isHidden = params.hidden; break;
      case 'move': partition.offset = params.offset; break;
      case 'convert': partition.fileSystem = params.fileSystem;if(params.label!=null)partition.label=params.label;break;
    }
  }
  for (const disk of projected.disks ?? []) disk.partitions.sort((a, b) => a.offset - b.offset);
  return projected;
}

function protectionReason(partition) {
  if (partition.isProtected) return partition.protectionReason || 'This partition is protected.';
  if (partition.isBoot || partition.isSystem) return 'Windows boot and system partitions are protected.';
  if (partition.isReadOnly) return 'This partition is read-only.';
  const gptType = normalizeId(partition.gptType).replace(/[{}]/g, '');
  if (PROTECTED_GPT_TYPES.has(gptType) || /recovery|reserved|system/i.test(partition.type ?? '')) {
    return 'System, recovery, and reserved partitions are protected.';
  }
  return null;
}

function validateFileSystem(params, size) {
  if (!FILE_SYSTEMS.has(params.fileSystem)) return 'Choose NTFS, exFAT, or FAT32.';
  if (params.fileSystem === 'FAT32' && size > 32 * GIB) return 'Windows formats FAT32 volumes up to 32 GB. Choose NTFS or exFAT.';
  if (params.allocationUnitSize != null && ![0, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432].includes(params.allocationUnitSize)) return 'Choose a supported allocation unit size.';
  if (params.fullFormat != null && typeof params.fullFormat !== 'boolean') return 'Choose quick or full formatting.';
  if (params.enableCompression && (params.fileSystem !== 'NTFS' || (params.allocationUnitSize || 4096) > 4096)) return 'NTFS compression requires allocation units of 4096 bytes or smaller.';
  return validateLabel(params.label ?? '', params.fileSystem);
}

function validateLabel(label, fileSystem) {
  if (typeof label !== 'string') return 'Enter a valid volume label.';
  const max = ['FAT','FAT32'].includes(fileSystem) ? 11 : fileSystem === 'exFAT' ? 15 : 32;
  if (label.length > max) return `${fileSystem || 'Volume'} labels can contain up to ${max} characters.`;
  if (/[\\/:*?"<>|\u0000-\u001f]/.test(label)) return 'The volume label contains an unsupported character.';
  return null;
}

function validateLetter(letter, inventory, target) {
  if (typeof letter !== 'string' || !/^[A-Z]?$/.test(letter)) return 'Choose a drive letter from A to Z, or no drive letter.';
  if (!letter) return null;
  for (const disk of inventory.disks ?? []) {
    for (const partition of disk.partitions ?? []) {
      if (partition === target) continue;
      if (String(partition.driveLetter ?? '').toUpperCase() === letter) return `Drive letter ${letter}: is already in use.`;
    }
  }
  return null;
}

/** Validate a new queue entry against the changes already in the queue. */
export function validateOperation(operation, snapshot, queuedOperations = []) {
  if (!operation || !SUPPORTED_OPERATIONS.has(operation.type)) return 'This operation is not supported.';
  if (!snapshot || !Array.isArray(snapshot.disks)) return 'Refresh the disk inventory first.';
  const inventory = projectInventory(snapshot, queuedOperations);
  const disk = inventory.disks.find((item) => item.number === operation.diskNumber);
  if (!disk) return 'The selected disk is no longer available. Refresh the disk inventory.';
  if (!normalizeId(operation.diskUniqueId) || normalizeId(operation.diskUniqueId) !== normalizeId(disk.uniqueId)) {
    return 'The disk identity changed. Refresh the disk inventory.';
  }
  if (disk.isOffline) return 'This disk is offline.';
  if (disk.isReadOnly) return 'This disk is read-only.';
  const params = operation.params ?? {};
  if (operation.type === 'initialize') {
    if (String(disk.partitionStyle).toUpperCase() !== 'RAW' || disk.partitions.length) return 'Only an empty, uninitialized disk can be initialized.';
    if (params.partitionStyle !== 'GPT') return 'Choose GPT partition style.';
    if (disk.isBoot || disk.isSystem) return 'Windows boot and system disks are protected.';
    return null;
  }
  if (!['GPT', 'MBR'].includes(String(disk.partitionStyle).toUpperCase())) return 'Initialize the disk before creating or editing partitions.';
  if (operation.type === 'create') {
    if (!integerBytes(params.offset) || !integerBytes(params.size) || params.size < MIB || params.offset % MIB || params.size % MIB) {
      return 'Enter a valid partition offset and size aligned to 1 MB.';
    }
    const gap = getSegments(disk).find((segment) => segment.unallocated &&
      params.offset >= segment.offset && params.offset + params.size <= segment.offset + segment.size);
    if (!gap) return 'The new partition must fit entirely within the selected unallocated space.';
    return validateFileSystem(params, params.size) || validateLetter(params.driveLetter ?? '', inventory, null);
  }
  if (!Number.isInteger(operation.partitionNumber) || operation.partitionNumber < 1 || !integerBytes(operation.partitionOffset)) {
    return 'Select an existing partition. Newly queued volumes can be edited after applying changes.';
  }
  const partition = findPartition(disk, operation);
  if (!partition) return 'The selected partition changed or is already queued for deletion.';
  const protectedReason = protectionReason(partition);
  if (protectedReason) return protectedReason;
  switch (operation.type) {
    case 'move': {
      if (!integerBytes(params.offset) || params.offset < MIB || params.offset % MIB) return 'Choose a starting offset aligned to 1 MiB.';
      if (params.offset === partition.offset) return 'Choose a different starting position.';
      if (!['NTFS', 'FAT', 'FAT32', 'EXFAT'].includes(String(partition.fileSystem || '').toUpperCase())) return 'Moving requires a recognized NTFS, FAT, FAT32, or exFAT data volume.';
      if (typeof params.stagingDirectory !== 'string' || !params.stagingDirectory.trim()) return 'Choose a staging folder on another physical disk.';
      if (params.offset + partition.size > disk.size - MIB) return 'The moved partition would extend past the usable disk area.';
      if (disk.partitions.some((other) => other !== partition && params.offset < other.offset + other.size && params.offset + partition.size > other.offset)) return 'The destination overlaps another partition.';
      return null;
    }
    case 'copy': {
      if (!['NTFS','FAT','FAT32','EXFAT'].includes(String(partition.fileSystem||'').toUpperCase())) return 'Choose a recognized NTFS, FAT, FAT32, or exFAT source volume.';
      const destination = params.destination;
      if (!destination || !integerBytes(destination.diskNumber)) return 'Select destination unallocated space.';
      const destinationDisk = inventory.disks.find((item) => item.number === destination.diskNumber);
      if (!destinationDisk || normalizeId(destination.diskUniqueId) !== normalizeId(destinationDisk.uniqueId)) return 'The destination disk identity changed.';
      if (destinationDisk.isOffline || destinationDisk.isReadOnly) return 'The destination disk is unavailable or read-only.';
      if (!integerBytes(destination.offset) || destination.offset % MIB || destination.size !== partition.size) return 'A volume copy must preserve the source size and use an aligned destination.';
      const gap = getSegments(destinationDisk).find((segment) => segment.unallocated && destination.offset >= segment.offset && destination.offset + destination.size <= segment.offset + segment.size);
      if (!gap) return 'Select unallocated space large enough for the complete source volume.';
      return validateLabel(destination.label||'',partition.fileSystem)||validateLetter(destination.driveLetter || '', inventory, null);
    }
    case 'convert': {
      const source=String(partition.fileSystem||'').toUpperCase();
      if(!['NTFS','FAT','FAT32','EXFAT'].includes(source)||!FILE_SYSTEMS.has(params.fileSystem))return 'Choose a recognized source and an NTFS, FAT32, or exFAT target.';
      if(source===params.fileSystem.toUpperCase())return 'Choose a different target file system.';
      if(['FAT','FAT32'].includes(source)&&params.fileSystem==='NTFS')return null;
      if(typeof params.stagingDirectory!=='string'||!params.stagingDirectory.trim())return 'Choose a staging folder on another physical NTFS disk for the complete recovery image and files.';
      if(source==='NTFS'&&params.fileSystem!=='NTFS'&&params.allowMetadataChanges!==true)return 'Confirm that the target cannot retain NTFS-only metadata.';
      return validateFileSystem({...params,label:params.label||''},partition.size);
    }
    case 'resize': {
      if (!integerBytes(params.size) || params.size < MIB || params.size % MIB) return 'Enter a partition size aligned to 1 MB.';
      if (!['NTFS', 'RAW', ''].includes(String(partition.fileSystem ?? '').toUpperCase())) return 'Windows supports resizing NTFS and unformatted partitions.';
      if (params.size === partition.size) return 'Enter a different partition size.';
      const nextPartition = disk.partitions.filter((item) => item.offset > partition.offset).sort((a, b) => a.offset - b.offset)[0];
      const endLimit = nextPartition ? nextPartition.offset : alignedDown(disk.size - MIB);
      if (partition.offset + params.size > endLimit) return 'Growing a partition requires adjacent unallocated space on its right.';
      if (partition.sizeRemaining != null && params.size < partition.size - partition.sizeRemaining) return 'The new size is smaller than the data stored on this volume.';
      return null;
    }
    case 'format': return validateFileSystem(params, partition.size);
    case 'delete': return null;
    case 'letter': return validateLetter(params.driveLetter ?? '', inventory, partition);
    case 'label': return validateLabel(params.label, partition.fileSystem);
    case 'hide': return typeof params.hidden === 'boolean' ? null : 'Choose whether to hide or show the partition.';
    default: return 'This operation is not supported.';
  }
}

export function operationIsDestructive(operation) {
  return ['format', 'delete'].includes(operation.type);
}

export function describeOperation(operation) {
  const target = operation.targetLabel || (operation.partitionNumber ? `Partition ${operation.partitionNumber}` : `Disk ${operation.diskNumber}`);
  const params = operation.params ?? {};
  switch (operation.type) {
    case 'create': return `Create ${params.label || 'New Volume'}${params.driveLetter ? ` (${params.driveLetter}:)` : ''} · ${formatBytes(params.size)}`;
    case 'resize': return `Resize ${target} to ${formatBytes(params.size)}`;
    case 'format': return `Format ${target} as ${params.fileSystem}`;
    case 'delete': return `Delete ${target}`;
    case 'letter': return params.driveLetter ? `Change ${target} to ${params.driveLetter}:` : `Remove drive letter from ${target}`;
    case 'label': return `Rename ${target} to “${params.label || '(no label)'}”`;
    case 'hide': return `${params.hidden ? 'Hide' : 'Show'} ${target}`;
    case 'initialize': return `Initialize Disk ${operation.diskNumber} as GPT`;
    case 'move': return `Move ${target} to ${formatBytes(params.offset)} from the start of the disk`;
    case 'copy': return `Copy ${target} to Disk ${params.destination?.diskNumber}${params.destination?.driveLetter ? ' (' + params.destination.driveLetter + ':)' : ''}`;
    case 'convert': return `Convert ${target} to ${params.fileSystem}${params.stagingDirectory?' using verified image and file staging':' without formatting'}`;
    default: return String(operation.type ?? 'Unknown operation');
  }
}
