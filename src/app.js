import { formatBytes, escapeHtml as esc, getSegments, projectInventory, describeOperation, validateOperation, MIB, GIB } from './model.js';
import { createPreviewBridge } from './preview.js';
import { createFeatureUI } from './features.js';

const preview = new URL(location.href).searchParams.get('preview') === '1';
const api = window.partly || (preview ? createPreviewBridge() : null);
const $ = (id) => document.getElementById(id);
const state = { snapshot: null, queue: [], redo: [], selected: null, page: 'disks', busy: false, settings: { refreshOnFocus: true, showSystemPartitions: true, confirmDiscard: true }, modal: false };
const icons = {
  resize: '↔', format: '◉', delete: '×', letter: 'A', label: '◇', properties: 'ⓘ', hide: '◌', check: '✓', create: '+', initialize: '⊞',copy:'▣',move:'↔',convert:'⇧',surface:'✓',sectors:'◴',undelete:'↶'
};
const actionNames = { resize: 'Move or Resize', format: 'Format volume', delete: 'Delete partition', letter: 'Change drive letter', label: 'Change volume label', properties: 'Properties', hide: 'Hide partition', check: 'Check file system', create: 'Create volume', initialize: 'Initialize disk',copy:'Copy volume',move:'Move partition',convert:'Convert file system',surface:'Test surface',sectors:'View / edit sectors',undelete:'Undelete volumes' };

function toast(message, error = false) {
  const item = document.createElement('div');
  item.className = 'toast' + (error ? ' error' : '');
  item.setAttribute('role', error ? 'alert' : 'status');
  item.textContent = message;
  $('toast-root').append(item);
  setTimeout(() => item.remove(), 6500);
}
function messageOf(error) { return String(error?.message || error).replace(/^Error invoking remote method '[^']+': (Error: )?/, ''); }
function projected() { return state.snapshot ? projectInventory(state.snapshot, state.queue) : { disks: [] }; }
function selection() {
  if (!state.selected) return null;
  const disk = projected().disks.find((entry) => entry.number === state.selected.diskNumber);
  if (!disk) return null;
  if (state.selected.diskOnly) return { disk, diskOnly: true };
  const segment = getSegments(disk).find((entry) => entry.key === state.selected.key);
  return segment ? { disk, segment } : null;
}
function targetLabel(disk, partition) {
  if (!partition) return `Disk ${disk.number}`;
  if (partition.unallocated) return `Unallocated on Disk ${disk.number}`;
  return `${partition.label || partition.type || 'Partition ' + partition.partitionNumber}${partition.driveLetter ? ' (' + partition.driveLetter + ':)' : ''}`;
}
function targetFor(disk, partition) {
  return { diskNumber: disk.number, diskUniqueId: disk.uniqueId, partitionNumber: partition?.partitionNumber, partitionOffset: partition?.offset, targetLabel: targetLabel(disk, partition) };
}
function render() {
  document.querySelectorAll('[data-page]').forEach((button) => {
    const active = button.dataset.page === state.page;
    button.classList.toggle('active', active);
    button.setAttribute('aria-current', active ? 'page' : 'false');
  });
  $('disk-page').hidden = state.page !== 'disks';
  $('secondary-page').hidden = state.page === 'disks';
  renderSidebar();
  renderFooter();
  if (state.page === 'disks') renderDisks();
}
function renderSidebar() {
  $('sidebar-title').textContent = state.page === 'settings' ? 'Settings & Tools' : state.page === 'history' ? 'Activity' : state.page === 'help' ? 'Help' : 'Operations';
  const selected = selection();
  const list = $('operation-list');
  list.innerHTML = '';
  $('sidebar-empty').hidden = Boolean(selected) || state.page !== 'disks';
  if (featureUI.renderSidebar()) return;
  if (state.page !== 'disks') {
    const description = document.createElement('p');
    description.className = 'sidebar-description';
    description.textContent = state.page === 'settings' ? 'Make Partly 20 work the way you do.' : state.page === 'history' ? 'A local record of changes made with Partly 20.' : 'Everything you need to get started.';
    list.append(description);
    return;
  }
  if (!selected) return;
  const { disk, segment } = selected;
  const actions = selected.diskOnly ? (disk.partitionStyle === 'RAW' ? ['initialize','properties','surface','sectors'] : ['properties','surface','sectors']) : segment.unallocated ? ['undelete','create','properties','surface','sectors'] : ['copy','resize','format','delete','letter','label','properties','hide','check','surface','convert','sectors'];
  for (const type of actions) {
    const button = document.createElement('button');
    button.className = 'operation-button';
    button.innerHTML = `<span class="operation-icon" aria-hidden="true">${icons[type]}</span><span>${type === 'hide' && segment?.isHidden ? 'Unhide partition' : actionNames[type]}</span>`;
    const protectedTarget = segment?.isProtected || segment?.isBoot || segment?.isSystem;
    const pendingNew = segment?.isPending && segment?.partitionNumber < 0;
    const readAction=['properties','surface','sectors','undelete','check'].includes(type);
    button.disabled = state.busy || (!readAction && (disk.isOffline || disk.isReadOnly || pendingNew || protectedTarget));
    if (button.disabled) button.title = pendingNew ? 'Apply the new volume before making more changes to it.' : segment?.protectionReason || 'This target is protected or unavailable.';
    button.addEventListener('click', () => runAction(type));
    list.append(button);
  }
  if (segment?.isProtected) {
    const note = document.createElement('p');
    note.className = 'sidebar-description';
    note.textContent = segment.protectionReason || 'Windows manages this protected partition.';
    list.append(note);
  }
}
function renderFooter() {
  const count = state.queue.length;
  $('discard-all').disabled = !count || state.busy;
  $('undo').disabled = !count || state.busy;
  $('redo').disabled = !state.redo.length || state.busy;
  $('apply-changes').disabled = !count || state.busy;
  $('apply-changes').textContent = count ? `Apply ${count} operation${count === 1 ? '' : 's'}` : 'Apply';
  $('pending-summary').textContent = state.busy ? 'Working…' : count ? `${count} pending change${count === 1 ? '' : 's'} · not applied yet` : 'No pending changes';
  $('refresh-disks').disabled = state.busy;
}
function renderDisks() {
  const selected = selection();
  $('workspace-title').textContent = selected ? targetLabel(selected.disk, selected.segment) : 'Select a disk or volume…';
  $('workspace-subtitle').textContent = state.queue.length ? 'Previewing pending changes. Your disks have not been changed.' : 'Disks & Volumes';
  if (!state.snapshot) return;
  const disks = projected().disks;
  $('inventory-status').innerHTML = `${preview ? '<span class="preview-badge">UI preview</span> ' : ''}<span class="status-dot"></span>${disks.length} disk${disks.length === 1 ? '' : 's'} · ${state.snapshot.isAdmin ? 'Administrator' : 'Read access'} <span class="scan-time">· Updated ${new Date(state.snapshot.scannedAt || Date.now()).toLocaleTimeString(state.settings.language||'en-US', { hour: '2-digit', minute: '2-digit' })}</span>${!state.snapshot.isAdmin && !preview ? ' <button class="inline-button" id="elevate">Restart as administrator</button>' : ''}`;
  $('elevate')?.addEventListener('click', elevate);
  if (!disks.length) {
    $('disk-list').innerHTML = '<div class="empty-workspace"><span class="empty-disk">▱</span><h2>No disks found</h2><p>Connect a drive, then refresh the disk list.</p></div>';
    return;
  }
  $('disk-list').innerHTML = disks.map((disk) => {
    const segments = getSegments(disk);
    const segmentsMarkup = segments.map((partition) => {
      const isSelected = state.selected?.key === partition.key;
      const used = Math.max(0, partition.size - (partition.sizeRemaining || 0));
      const usedPercent = partition.unallocated ? 0 : partition.sizeRemaining == null ? 100 : Math.min(100, used / partition.size * 100);
      const title = targetLabel(disk, partition);
      const tiny = partition.size < disk.size * 0.025;
      const filtered = !state.settings.showSystemPartitions && partition.isProtected;
      return `<button class="partition${partition.unallocated ? ' unallocated' : ''}${isSelected ? ' selected' : ''}${partition.isProtected ? ' protected' : ''}${partition.isPending ? ' pending' : ''}${tiny ? ' small-partition' : ''}${filtered ? ' muted-partition' : ''}" data-segment="${esc(partition.key)}" data-disk="${disk.number}" style="flex-grow:${Math.max(0.001, partition.size / disk.size)};flex-basis:${tiny ? 42 : 76}px" title="${esc(title)} · ${formatBytes(partition.size)}${partition.isProtected ? ' · Protected' : ''}" aria-label="${esc(title)}, ${formatBytes(partition.size)}${isSelected ? ', selected' : ''}" aria-pressed="${isSelected}"><span class="partition-track"><span class="partition-fill" style="width:${usedPercent}%"></span><span class="partition-label">${partition.isBoot ? '<span class="windows-mark" aria-hidden="true">⊞</span> ' : ''}${esc(partition.unallocated ? 'Unallocated' : partition.label || partition.type || 'Local Disk')}${partition.driveLetter ? ' (' + esc(partition.driveLetter) + ':)' : ''}</span></span><span class="partition-detail">${formatBytes(partition.size)}${!partition.unallocated && !tiny && partition.sizeRemaining != null ? ' <span class="used-detail">(' + formatBytes(used) + ' used)</span>' : ''}</span><span class="partition-filesystem">${esc(partition.unallocated ? 'Free space' : partition.fileSystem || partition.type || 'Unknown')}${partition.isPending ? ' · Pending' : ''}${partition.isProtected ? ' · Protected' : ''}</span></button>`;
    }).join('');
    return `<section class="disk-card${disk.isOffline ? ' disk-offline' : ''}" aria-label="Disk ${disk.number}: ${esc(disk.friendlyName)}"><div class="disk-header"><span>${esc(disk.friendlyName || 'Windows disk')}</span><span>${formatBytes(disk.size)} <span class="disk-style">Basic ${esc(disk.partitionStyle)}</span></span></div><div class="disk-body"><button class="disk-identity${state.selected?.diskOnly && state.selected.diskNumber === disk.number ? ' selected' : ''}" data-select-disk="${disk.number}" aria-label="Select Disk ${disk.number}"><svg viewBox="0 0 72 48" aria-hidden="true"><path d="M5 22 34 7l33 12-29 16z" fill="#c5e6f6"/><path d="M5 22v13l33 10V35z" fill="#79a6bb"/><path d="m38 35 29-16v14L38 45z" fill="#98c4d9"/><circle cx="13" cy="33" r="1.8" fill="white"/></svg><span>Disk ${disk.number}</span><span class="disk-online">${disk.isOffline ? 'Offline' : 'Online'}${disk.isReadOnly ? ' · Read only' : ''}</span></button><div class="partition-map">${segmentsMarkup || '<div class="raw-disk">Uninitialized disk · Select Disk ' + disk.number + ' to initialize</div>'}</div></div></section>`;
  }).join('');
  $('disk-list').querySelectorAll('[data-segment]').forEach((button) => button.addEventListener('click', () => { state.selected = { key: button.dataset.segment, diskNumber: Number(button.dataset.disk) }; render(); }));
  $('disk-list').querySelectorAll('[data-select-disk]').forEach((button) => button.addEventListener('click', () => { state.selected = { diskOnly: true, diskNumber: Number(button.dataset.selectDisk) }; render(); }));
}
async function refresh({ silent = false } = {}) {
  if (state.busy || state.queue.length) { if (!silent) toast('Apply or discard pending changes before refreshing.'); return; }
  if (!api) return;
  state.busy = true;
  renderFooter();
  if (!state.snapshot) $('disk-list').innerHTML = '<div class="empty-workspace"><div class="spinner"></div><h2>Reading your disks…</h2><p>Getting the current layout from Windows.</p></div>';
  try {
    const inventory = await api.inventory();
    if (!inventory || !Array.isArray(inventory.disks)) throw new Error('Windows returned an invalid disk inventory.');
    state.snapshot = inventory;
    if (state.selected && !selection()) state.selected = null;
  } catch (error) {
    toast(messageOf(error), true);
    if (!state.snapshot) {
      $('inventory-status').textContent = 'Disk inventory unavailable';
      $('disk-list').innerHTML = `<div class="empty-workspace"><span class="empty-disk">▱</span><h2>Couldn’t read your disks</h2><p>${esc(messageOf(error))}</p><button class="button" id="retry-inventory">Try again</button><button class="button button-primary" id="retry-admin">Restart as administrator</button></div>`;
      $('retry-inventory').onclick = () => refresh();
      $('retry-admin').onclick = elevate;
    }
  } finally { state.busy = false; render(); }
}
function closeModal() {
  if (state.busy && $('operation-progress')) return;
  $('modal-root').replaceChildren();
  state.modal = false;
  document.removeEventListener('keydown', modalKeys);
  $('apply-changes').focus();
}
function modalKeys(event) {
  if (event.key === 'Escape') closeModal();
  if (event.key === 'Tab') {
    const focusable = [...$('modal-root').querySelectorAll('button:not(:disabled),input:not(:disabled),select:not(:disabled),a[href]')].filter((entry) => !entry.hidden);
    const first = focusable[0], last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  }
}
function openModal(title, content, actions = [{ label: 'Close', onClick: closeModal }], setup) {
  $('modal-root').innerHTML = `<div class="modal-backdrop"><section class="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title"><header class="modal-header"><h2 id="modal-title">${esc(title)}</h2><button class="modal-close" id="modal-close" aria-label="Close dialog">×</button></header><div class="modal-body">${content}<p class="form-error" id="form-error" role="alert" hidden></p></div><footer class="modal-footer" id="modal-actions"></footer></section></div>`;
  state.modal = true;
  $('modal-close').onclick = closeModal;
  for (const action of actions) {
    const button = document.createElement('button');
    button.className = 'button ' + (action.primary ? 'button-primary' : action.danger ? 'button-danger' : '');
    button.textContent = action.label;
    if (action.id) button.id = action.id;
    button.onclick = async () => {
      try { await action.onClick(); } catch (error) { formError(messageOf(error)); }
    };
    $('modal-actions').append(button);
  }
  document.removeEventListener('keydown', modalKeys);
  document.addEventListener('keydown', modalKeys);
  setup?.();
  setTimeout(() => ($('modal-root').querySelector('input,select') || $('modal-close'))?.focus(), 30);
}
function formError(message) { const error = $('form-error'); if (error) { error.hidden = false; error.textContent = message; } else toast(message, true); }
function queueOperation(type, disk, partition, params = {}) {
  if (!state.snapshot.isAdmin && !preview) throw new Error('Restart Partly 20 as administrator before queuing disk changes.');
  const operation = { id: crypto.randomUUID(), type, ...targetFor(disk, partition), params };
  const error = validateOperation(operation, state.snapshot, state.queue);
  if (error) throw new Error(error);
  state.queue.push(operation);
  state.redo = [];
  closeModal();
  if (!selection()) state.selected = { diskNumber: disk.number, diskOnly: true };
  render();
  toast('Change queued. Choose Apply to write it to disk.');
}
function volumeSummary(disk, partition) {
  return `<div class="target-summary"><span class="target-icon">▱</span><div><strong>${esc(targetLabel(disk, partition))}</strong><p>Disk ${disk.number} · ${partition ? formatBytes(partition.size) + ' · ' + esc(partition.fileSystem || (partition.unallocated ? 'Unallocated' : partition.type || 'Partition')) : esc(disk.friendlyName)}</p></div></div>`;
}
function letterOptions(current = '', allowNone = true) {
  const used = projected().disks.flatMap((disk) => disk.partitions.map((partition) => partition.driveLetter)).filter(Boolean);
  return (allowNone ? '<option value="">No drive letter</option>' : '') + 'DEFGHIJKLMNOPQRSTUVWXYZAB'.split('').filter((letter) => !used.includes(letter) || letter === current).map((letter) => `<option value="${letter}"${letter === current ? ' selected' : ''}>${letter}:</option>`).join('');
}
async function runAction(type) {
  const selected = selection();
  if (!selected || state.busy) return;
  const { disk, segment: partition } = selected;
  if (featureUI.runAction(type,selected)) return;
  const summary = volumeSummary(disk, partition);
  const buttons = (commit) => [{ label: 'Cancel', onClick: closeModal }, { label: 'Place in queue', primary: true, onClick: commit }];
  if (type === 'properties') {
    const values = partition ? { 'Disk number': disk.number, 'Partition number': partition.unallocated ? '—' : partition.partitionNumber, 'Capacity': formatBytes(partition.size), 'Used space': partition.sizeRemaining == null ? '—' : formatBytes(partition.size - partition.sizeRemaining), 'File system': partition.fileSystem || '—', 'Offset': `${partition.offset.toLocaleString()} bytes`, 'Drive letter': partition.driveLetter ? partition.driveLetter + ':' : 'None', 'Partition type': partition.type || 'Unallocated', 'Protected': partition.isProtected ? 'Yes' : 'No', 'Disk ID': disk.uniqueId } : { 'Device': disk.friendlyName, 'Disk number': disk.number, 'Capacity': formatBytes(disk.size), 'Partition style': disk.partitionStyle, 'Connection': disk.busType, 'Health': disk.healthStatus, 'Status': disk.operationalStatus, 'Read only': disk.isReadOnly ? 'Yes' : 'No', 'Serial number': disk.serialNumber || '—', 'Disk ID': disk.uniqueId };
    openModal('Properties', summary + '<dl class="properties-grid">' + Object.entries(values).map(([key, value]) => `<dt>${esc(key)}</dt><dd>${esc(String(value ?? '—'))}</dd>`).join('') + '</dl>');
  } else if (type === 'delete') {
    const operation={id:crypto.randomUUID(),type:'delete',...targetFor(disk,partition),params:{}};
    const before=projected(),after=projectInventory(before,[operation]),maps=featureUI.previewMaps(before,after);
    openModal('Delete partition', summary + '<div class="notice notice-warning"><strong>This removes the partition and all its files.</strong><p>Its space becomes unallocated. Choose Place in queue to review it later, or Delete now for immediate execution after confirmation.</p></div><div class="preview-tabs"><button id="delete-before">Before changes</button><button class="active" id="delete-after">After changes</button></div><div class="layout-preview" id="delete-layout">'+maps.after+'</div><button class="inline-button" id="delete-notifications">Notifications</button>',[{label:'Cancel',onClick:closeModal},{label:'Delete now',danger:true,onClick:()=>{if(state.queue.length)throw new Error('Apply or discard the existing queue before deleting immediately.');return applyChanges([operation]);}},{label:'Place in queue',primary:true,onClick:()=>queueOperation(type,disk,partition)}],()=>{
      $('delete-before').onclick=()=>{$('delete-layout').innerHTML=maps.before;$('delete-before').classList.add('active');$('delete-after').classList.remove('active');};$('delete-after').onclick=()=>{$('delete-layout').innerHTML=maps.after;$('delete-after').classList.add('active');$('delete-before').classList.remove('active');};$('delete-notifications').onclick=()=>{closeModal();featureUI.openSettings('notifications');};
    });
  } else if (type === 'format' || type === 'create') {
    const creating = type === 'create';
    const maxMiB = Math.floor(partition.size / MIB);
    openModal(creating ? 'Create new volume' : 'Format volume', summary + `${!creating ? '<div class="notice notice-warning">Formatting permanently removes all files on this volume when applied.</div>' : ''}<div class="form-grid"><label>Volume label<input id="volume-label" maxlength="32" value="${esc(creating ? 'New Volume' : partition.label || '')}" placeholder="New Volume"></label><label>File system<select id="file-system"><option>NTFS</option><option>exFAT</option><option>FAT32</option></select></label>${creating ? `<label>Volume size (MiB)<input id="volume-size" type="number" min="1" max="${maxMiB}" step="1" value="${maxMiB}"><span class="field-help">Maximum ${formatBytes(partition.size)}</span></label><label>Drive letter<select id="drive-letter">${letterOptions('', false)}</select></label>` : ''}</div>${creating?`<input id="create-size-slider" class="size-slider" aria-label="Volume size" type="range" min="1" max="${maxMiB}" value="${maxMiB}">`:''}<details class="advanced-options"><summary>Show advanced options</summary><div class="form-grid"><label>Allocation unit size<select id="allocation-size"><option value="0">Windows default</option>${[512,1024,2048,4096,8192,16384,32768,65536,131072,262144,1048576].map(size=>`<option value="${size}">${formatBytes(size)}</option>`).join('')}</select></label></div><label class="checkbox-row"><input id="quick-format" type="checkbox" checked>Quick format</label><label class="checkbox-row"><input id="format-compression" type="checkbox">Enable NTFS compression</label></details><p class="muted-note">Formatting uses Windows Storage. FAT32 is limited to 32 GiB.</p>`, buttons(() => {
      const fileSystem = $('file-system').value;
      const params = { fileSystem, label: $('volume-label').value.trim(),allocationUnitSize:Number($('allocation-size').value),fullFormat:!$('quick-format').checked,enableCompression:$('format-compression').checked };
      if (creating) Object.assign(params, { size: Number($('volume-size').value) * MIB, offset: partition.offset, driveLetter: $('drive-letter').value });
      queueOperation(type, disk, partition, params);
    }), () => {
      if (!creating && ['NTFS', 'exFAT', 'FAT32'].includes(partition.fileSystem)) $('file-system').value = partition.fileSystem;
      if(creating){
        $('volume-size').oninput=()=>{$('create-size-slider').value=$('volume-size').value;};
        $('create-size-slider').oninput=()=>{$('volume-size').value=$('create-size-slider').value;};
        $('modal-root').querySelector('.modal-body').insertAdjacentHTML('beforeend','<div class="preview-tabs" role="tablist"><button id="create-before" role="tab" aria-selected="false">Before changes</button><button id="create-after" class="active" role="tab" aria-selected="true">After changes</button></div><div class="layout-preview" id="create-layout"></div><button class="inline-button" id="create-notifications">Notifications</button>');
        let showAfter=true;
        const updatePreview=()=>{
          const size=Number($('volume-size').value)*MIB,before=projected();
          if(!Number.isSafeInteger(size)||size<MIB||size>partition.size){$('create-layout').textContent='Enter a valid volume size to preview its layout.';return;}
          const operation={id:'create-dialog-preview',type:'create',...targetFor(disk,partition),params:{offset:partition.offset,size,label:$('volume-label').value,fileSystem:$('file-system').value,driveLetter:$('drive-letter').value}};
          const maps=featureUI.previewMaps(before,projectInventory(before,[operation]));
          $('create-layout').innerHTML=showAfter?maps.after:maps.before;
          $('create-before').classList.toggle('active',!showAfter);$('create-after').classList.toggle('active',showAfter);
          $('create-before').setAttribute('aria-selected',String(!showAfter));$('create-after').setAttribute('aria-selected',String(showAfter));
        };
        $('create-before').onclick=()=>{showAfter=false;updatePreview();};$('create-after').onclick=()=>{showAfter=true;updatePreview();};
        for(const id of ['volume-label','volume-size','file-system','drive-letter','create-size-slider']){ $(id).addEventListener('input',updatePreview);$(id).addEventListener('change',updatePreview); }
        $('create-notifications').onclick=()=>{closeModal();featureUI.openSettings('notifications');};
        updatePreview();
      }
    });
  } else if (type === 'resize') {
    openModal('Move or Resize', summary + '<div id="resize-fields"><div class="spinner"></div><p>Checking supported sizes with Windows…</p></div>', [{ label: 'Cancel', onClick: closeModal }]);
    try {
      const limits = await api.limits(targetFor(disk, partition));
      if (!state.modal || !$('resize-fields')) return;
      const minimum = Math.ceil(limits.sizeMin / MIB), maximum = Math.floor(limits.sizeMax / MIB);
      $('resize-fields').innerHTML = `<label class="form-label">New volume size (MiB)<input id="resize-size" type="number" min="${minimum}" max="${maximum}" step="1" value="${Math.min(maximum, Math.max(minimum, Math.floor(partition.size / MIB)))}"></label><input aria-label="New partition size" class="size-slider" id="resize-slider" type="range" min="${minimum}" max="${maximum}" step="1" value="${Math.min(maximum, Math.max(minimum, Math.floor(partition.size / MIB)))}"><div class="range-labels"><span>Minimum ${formatBytes(limits.sizeMin)}</span><span>Maximum ${formatBytes(limits.sizeMax)}</span></div><p class="muted-note">Windows can shrink or extend the right edge of this volume. Moving its starting position is unavailable.</p>`;
      $('resize-size').oninput = () => { $('resize-slider').value = $('resize-size').value; };
      $('resize-slider').oninput = () => { $('resize-size').value = $('resize-slider').value; };
      const commit = document.createElement('button');
      commit.className = 'button button-primary'; commit.textContent = 'Place in queue';
      commit.onclick = () => { const value = Number($('resize-size').value); if (!Number.isInteger(value) || value < minimum || value > maximum) return formError('Choose a size inside the supported range.'); try { queueOperation(type, disk, partition, { size: value * MIB }); } catch (error) { formError(messageOf(error)); } };
      $('modal-actions').append(commit);
    } catch (error) { formError(messageOf(error)); $('resize-fields').innerHTML = ''; }
  } else if (type === 'label') {
    openModal('Change volume label', summary + `<label class="form-label">Volume label<input id="volume-label" maxlength="32" value="${esc(partition.label || '')}"></label>`, buttons(() => queueOperation(type, disk, partition, { label: $('volume-label').value.trim() })));
  } else if (type === 'letter') {
    openModal('Change drive letter', summary + `<label class="form-label">New drive letter<select id="drive-letter">${letterOptions(partition.driveLetter || '')}</select></label><p class="muted-note">Applications using the old drive path may need to be updated.</p>`, buttons(() => queueOperation(type, disk, partition, { driveLetter: $('drive-letter').value })));
  } else if (type === 'hide') {
    const hidden = !partition.isHidden;
    openModal(hidden ? 'Hide partition' : 'Unhide partition', summary + `<p>${hidden ? 'The partition will be marked hidden in Windows. Its files will remain on disk.' : 'The hidden flag will be removed from this partition.'}</p>`, buttons(() => queueOperation(type, disk, partition, { hidden })));
  } else if (type === 'initialize') {
    openModal('Initialize disk', summary + '<p>Initialize this empty disk with the GPT partition style so you can create volumes.</p><div class="notice">Only an uninitialized disk with no partitions can be initialized.</div>', buttons(() => queueOperation(type, disk, null, { partitionStyle: 'GPT' })));
  } else if (type === 'check') {
    if (state.queue.length) { toast('Apply or discard queued changes before checking a file system.'); return; }
    openModal('Check file system', summary + '<p>Scan the volume with Windows to check its file system. This scan does not repair or format the volume.</p>', [{ label: 'Cancel', onClick: closeModal }, { label: 'Start scan', primary: true, onClick:()=>featureUI.task('check',{target:targetFor(disk,partition)},'Check file system',{refreshDisks:false}) }]);
  }
}
function reviewChanges() {
  if (!state.queue.length || state.busy) return;
  let selectedIndex=state.queue.length-1,useAfter=true;
  const maps=featureUI.previewMaps(state.snapshot,projected());
  openModal('Apply pending changes?', `<p class="modal-intro">Select an operation to review its effect on the disk layout.</p><ol class="operation-queue">${state.queue.map((operation,index) => `<li><button class="review-operation${index===selectedIndex?' active':''}" data-review-operation="${index}"><span class="queue-icon">${icons[operation.type]}</span><span><strong>${esc(describeOperation(operation))}</strong><span class="queue-target">${esc(operation.targetLabel)} · Disk ${operation.diskNumber}</span></span></button></li>`).join('')}</ol><div class="preview-tabs" role="tablist"><button id="before-tab" role="tab" aria-selected="false">Before changes</button><button id="after-tab" role="tab" aria-selected="true" class="active">After changes</button></div><div class="layout-preview" id="layout-preview">${maps.after}</div><label class="checkbox-row"><input id="power-off-complete" type="checkbox" ${state.powerOffWhenComplete?'checked':''}>Power off on complete</label><div class="notice notice-warning">Changes are written to real disks. Deleting or formatting a partition removes its data.</div><button id="review-notifications" class="inline-button">Notifications</button>`, [{label:'Discard all',onClick:discard},{label:'Undo',onClick:()=>{undo();state.queue.length?reviewChanges():closeModal();}},{label:'Redo',onClick:()=>{redo();reviewChanges();}},{ label: 'Cancel', onClick: closeModal }, { label: 'Apply changes', primary: true, onClick:()=>applyChanges(state.queue,{powerOffWhenComplete:$('power-off-complete').checked}) }], () => {
    const updateMap=()=>{const before=projectInventory(state.snapshot,state.queue.slice(0,selectedIndex)),after=projectInventory(state.snapshot,state.queue.slice(0,selectedIndex+1));const map=featureUI.previewMaps(before,after);$('layout-preview').innerHTML=useAfter?map.after:map.before;$('before-tab').classList.toggle('active',!useAfter);$('after-tab').classList.toggle('active',useAfter);$('before-tab').setAttribute('aria-selected',String(!useAfter));$('after-tab').setAttribute('aria-selected',String(useAfter));};
    $('before-tab').onclick=()=>{useAfter=false;updateMap();};$('after-tab').onclick=()=>{useAfter=true;updateMap();};
    document.querySelectorAll('[data-review-operation]').forEach(button=>button.onclick=()=>{selectedIndex=Number(button.dataset.reviewOperation);document.querySelectorAll('[data-review-operation]').forEach(entry=>entry.classList.toggle('active',entry===button));updateMap();});
    $('power-off-complete').onchange=()=>{state.powerOffWhenComplete=$('power-off-complete').checked;};$('review-notifications').onclick=()=>{closeModal();featureUI.openSettings('notifications');};
    const redoButton=[...$('modal-actions').querySelectorAll('button')].find(button=>button.textContent==='Redo');if(redoButton)redoButton.disabled=!state.redo.length;
  });
}
async function applyChanges(operations=state.queue,{powerOffWhenComplete=false}={}) {
  if (!state.snapshot.isAdmin) { formError('Restart Partly 20 as administrator before applying changes.'); return; }
  if (preview) { formError('This is a visual preview. Run the Windows desktop app to apply real disk changes.'); return; }
  state.busy = true; renderFooter();
  const unsubscribe = featureUI.progressView('Applying queued operations');
  try {
    const result = await api.apply({ operations, expectedSnapshot: state.snapshot,powerOffWhenComplete });
    state.busy = false;
    if (result.cancelled&&result.beforeExecution) { closeModal(); return; }
    state.queue = []; state.redo = []; state.selected = null;
    await refresh();
    const failed = result.success === false;
    const results = [...(result.results || result.operations || result.completed || []), ...(result.failedOperation ? [result.failedOperation] : [])];
    if(!failed&&state.settings.closeProgressAutomatically&&!result.shutdownScheduled){closeModal();toast('All tasks are completed.');}
    else openModal(result.cancelled?'Operations cancelled':failed ? 'Operations stopped' : 'All tasks are completed', `<div class="completion-icon${failed ? ' failed' : ''}">${failed ? '!' : '✓'}</div><p>${esc(result.error?.message || result.message || (failed ? 'A disk operation failed. The disk layout has been refreshed.' : 'Windows finished applying your changes.'))}</p>${result.recoveryJournal?'<p class="output-path">Recovery journal: '+esc(String(result.recoveryJournal))+'</p>':''}${results.length ? '<ul class="result-list">' + results.map((entry) => `<li><span>${entry.success === false || ['failed','cancelled'].includes(entry.status) ? '!' : '✓'}</span>${esc(entry.error || entry.message || actionNames[entry.type] || entry.type || entry.status || 'Completed')}</li>`).join('') + '</ul>' : ''}${result.shutdownScheduled?'<div class="notice notice-warning">Windows will shut down in 60 seconds.</div>':''}`,result.shutdownScheduled?[{label:'Cancel shutdown',onClick:async()=>{await api.cancelShutdown();toast('Scheduled shutdown cancelled.');closeModal();}},{label:'Close',primary:true,onClick:closeModal}]:undefined);
  } catch (error) {
    state.busy = false;
    // A failed batch can have partial changes. Never leave a stale queue ready to replay.
    state.queue = []; state.redo = []; state.selected = null;
    await refresh();
    openModal('Changes could not be completed', `<div class="notice notice-warning">${esc(messageOf(error))}</div><p>The queue was cleared and the current disk layout was reloaded. Review the disks before planning further changes.</p>`);
  } finally { unsubscribe?.(); state.busy = false; render(); }
}
function discard() {
  if (!state.queue.length || state.busy) return;
  const commit = () => { state.queue = []; state.redo = []; state.selected = null; closeModal(); render(); };
  if (state.settings.confirmDiscard) openModal('Discard pending changes?', '<p>Remove all queued operations? No disk changes have been applied.</p>', [{ label: 'Keep changes', onClick: closeModal }, { label: 'Discard all', primary: true, onClick: commit }]);
  else commit();
}
async function elevate() { try { await api.restartAsAdmin(); } catch (error) { toast(messageOf(error), true); } }
async function navigate(page) {
  state.page = page; render();
  if (featureUI.navigate(page)) return;
  const secondary = $('secondary-page');
  if (page === 'settings') {
    secondary.innerHTML = `<div class="secondary-heading"><span class="eyebrow">SETTINGS & TOOLS</span><h1>Application settings</h1><p>Everything stays on this computer.</p></div><div class="settings-list">${[['refreshOnFocus', 'Refresh disks automatically', 'Refresh the disk layout when you return to the app, while the queue is empty.'], ['showSystemPartitions', 'Highlight system partitions', 'Show protected partitions at full contrast in the disk map.'], ['confirmDiscard', 'Confirm before discarding changes', 'Ask before clearing the pending operation queue.']].map(([key, title, description]) => `<label class="setting-row"><div><strong>${title}</strong><p>${description}</p></div><input class="toggle" type="checkbox" data-setting="${key}" ${state.settings[key] ? 'checked' : ''}></label>`).join('')}</div><div class="settings-tools"><h2>Diagnostics</h2><p>Save the current disk inventory and operation history as a local JSON file. The file includes device identifiers and volume labels.</p><button class="button" id="export-diagnostics">Collect log files</button></div><div class="about-card"><div class="about-logo">P<span>20</span></div><div><h2>Partly 20</h2><p>Version 1.0.0 · Windows Disk & Partition Manager</p><span class="local-badge">Local device · No account required</span></div></div>`;
    secondary.querySelectorAll('[data-setting]').forEach((input) => input.onchange = async () => { state.settings[input.dataset.setting] = input.checked; try { state.settings = await api.setSettings(state.settings); } catch (error) { toast(messageOf(error), true); } });
    $('export-diagnostics').onclick = async () => { try { const result = await api.exportDiagnostics(); if (!result.cancelled) toast('Diagnostics saved to ' + result.path); } catch (error) { toast(messageOf(error), true); } };
  } else if (page === 'history') {
    secondary.innerHTML = '<div class="secondary-heading"><span class="eyebrow">LOCAL ACTIVITY</span><h1>Operation history</h1><p>Changes applied from this computer.</p></div><div id="history-list"><div class="spinner"></div></div>';
    try {
      const history = await api.getHistory();
      if (state.page !== 'history') return;
      $('history-list').innerHTML = history.length ? history.map((record) => `<article class="history-card"><div><strong>${record.status === 'completed' ? '✓ Completed' : '! Stopped'}</strong><time>${new Date(record.startedAt).toLocaleString()}</time></div><ul>${record.operations.map((operation) => `<li>${esc(describeOperation(operation))} · ${esc(operation.targetLabel || 'Disk ' + operation.diskNumber)}</li>`).join('')}</ul>${record.error ? '<p class="form-error">' + esc(record.error) + '</p>' : ''}</article>`).join('') : '<div class="empty-history"><span>◷</span><h2>No operations yet</h2><p>Once you apply a change, its result will appear here.</p></div>';
    } catch (error) { toast(messageOf(error), true); }
  } else if (page === 'help') {
    secondary.innerHTML = `<div class="secondary-heading"><span class="eyebrow">PARTLY 20</span><h1>Your disks, under your control.</h1><p>A local Windows partition manager. No account required.</p></div><div class="help-steps"><article><span>01</span><h2>Select a volume</h2><p>Choose a partition in the disk map to see its available operations. Select unallocated space to create or recover a volume.</p></article><article><span>02</span><h2>Plan your changes</h2><p>Place operations in the queue. Undo, redo, or discard them before applying. The disk map previews the resulting layout.</p></article><article><span>03</span><h2>Review & apply</h2><p>Review the before and after layouts, then apply. Windows asks for administrator access. Keep your drives connected until completion.</p></article></div><div class="settings-tools"><h2>Partition tools</h2><p>Create, move, copy, resize, format, delete, change letter or label, hide/unhide, check file systems, scan disk surfaces, recover lost volumes, and view or edit sectors.</p><p>Moving uses a verified full staging image on another physical disk. Volume copying preserves the source file system and assigns new volume identity. FAT/FAT32 converts directly to NTFS. Other NTFS, exFAT, and FAT32 conversions use a verified complete recovery image and file staging on another NTFS disk, then recreate the file system and verify every restored file. Recovery files are retained.</p><h2>Backup, migration, and recovery</h2><p>Create WIM or Windows system-image backups, restore to empty data volumes, copy Windows to an empty UEFI disk, convert VHD/VHDX files with the Windows virtual-disk engine, and create recovery media. QEMU and Windows ADK are optional dependencies for additional formats and custom WinPE media.</p><h2>Keyboard shortcuts</h2><p><kbd>Ctrl</kbd> + <kbd>Z</kbd> Undo · <kbd>Ctrl</kbd> + <kbd>Y</kbd> Redo · <kbd>F5</kbd> Refresh · <kbd>Esc</kbd> Close dialog</p></div>`;
  }
}
function undo() { if (state.busy || !state.queue.length) return; state.redo.push(state.queue.pop()); if (!selection()) state.selected = null; render(); }
function redo() { if (state.busy || !state.redo.length) return; const operation = state.redo.at(-1); const error = validateOperation(operation, state.snapshot, state.queue); if (error) return toast(error, true); state.queue.push(state.redo.pop()); render(); }

const featureUI=createFeatureUI({api,state,$,openModal,closeModal,toast,refresh,render,selection,targetFor,volumeSummary,queueOperation,formError,projected,letterOptions,navigate,runAction});
featureUI.initialize();

document.querySelectorAll('[data-page]').forEach((button) => button.onclick = () => navigate(button.dataset.page));
$('refresh-disks').onclick = () => refresh();
$('discard-all').onclick = discard;
$('undo').onclick = undo;
$('redo').onclick = redo;
$('apply-changes').onclick = reviewChanges;
for (const action of ['minimize', 'maximize', 'close']) $('window-' + action).onclick = () => api?.windowControl(action);
document.addEventListener('keydown', (event) => {
  if (event.target.matches('input,textarea,select') || state.modal) return;
  if (event.key === 'F5') { event.preventDefault(); refresh(); }
  if (event.ctrlKey && event.key.toLowerCase() === 'z') { event.preventDefault(); event.shiftKey ? redo() : undo(); }
  if (event.ctrlKey && event.key.toLowerCase() === 'y') { event.preventDefault(); redo(); }
});
window.addEventListener('focus', () => { if (state.settings.refreshOnFocus && !state.modal && !state.busy && !state.queue.length && state.snapshot) refresh({ silent: true }); });
window.addEventListener('beforeunload', (event) => { if (state.busy || state.queue.length) { event.preventDefault(); event.returnValue = ''; } });

if (!api) {
  $('inventory-status').textContent = 'Desktop app required';
  $('disk-list').innerHTML = '<div class="empty-workspace"><span class="empty-disk">▱</span><h2>Open Partly 20 for Windows</h2><p>Real disk access is available in the desktop app.</p></div>';
  render();
} else {
  api.getSettings().then((settings) => { state.settings = settings;if(settings.checkUpdatesAutomatically&&settings.updateFeed)api.checkUpdates().then(result=>{if(result.available)toast('An update to Partly 20 '+result.version+' is available. Check About to download it.');}).catch(error=>toast('Update check: '+error.message,true)); }).catch(() => {});
  refresh();
}
