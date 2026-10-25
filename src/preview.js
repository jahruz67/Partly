// Used only with an explicit ?preview=1 URL. The desktop always uses the real Windows bridge.
export function createPreviewBridge() {
  const GiB = 1024 ** 3, MiB = 1024 ** 2;
  // Reference capacities rounded to MiB, just like the actual operation inputs.
  // Keeping every extent integral makes delete/create/undo previews exercise the
  // same geometry validation as an inventory returned by Windows.
  const ssdSize = 488386 * MiB;
  const windowsOffset = 217 * MiB;
  const windowsSize = 486932 * MiB;
  const recoveryOffset = windowsOffset + windowsSize;
  const usbSize = 58675 * MiB;
  const fixture = { isAdmin: true, scannedAt: new Date().toISOString(), disks: [
    { number: 0, friendlyName: 'WDC PC SN730 SDBQNTY-512G-1001', serialNumber: 'REFERENCE-SSD', uniqueId: 'preview-0', size: ssdSize, partitionStyle: 'GPT', busType: 'NVMe', healthStatus: 'Healthy', operationalStatus: 'Online', isBoot: true, partitions: [
      { partitionNumber: 1, diskNumber: 0, offset: MiB, size: 200 * MiB, type: 'System', fileSystem: 'FAT32', label: 'EFI System', isSystem: true, isProtected: true, protectionReason: 'EFI system partition' },
      { partitionNumber: 2, diskNumber: 0, offset: 201 * MiB, size: 16 * MiB, type: 'Reserved', label: 'Reserved', isProtected: true },
      { partitionNumber: 3, diskNumber: 0, offset: windowsOffset, size: windowsSize, type: 'Basic', fileSystem: 'NTFS', label: 'Local Disk', driveLetter: 'C', sizeRemaining: 338872 * MiB, isBoot: true, isProtected: true, protectionReason: 'Windows operating system partition' },
      { partitionNumber: 4, diskNumber: 0, offset: recoveryOffset, size: ssdSize - recoveryOffset - MiB, type: 'Recovery', fileSystem: 'NTFS', label: 'Recovery', isProtected: true }
    ] },
    { number: 1, friendlyName: 'USB SanDisk 3.2Gen1 USB Device', serialNumber: 'REFERENCE-USB', uniqueId: 'preview-1', size: usbSize + 2 * MiB, partitionStyle: 'GPT', busType: 'USB', healthStatus: 'Healthy', operationalStatus: 'Online', partitions: [
      { partitionNumber: 1, diskNumber: 1, offset: MiB, size: usbSize, type: 'Basic', fileSystem: 'NTFS', label: 'CENA_X64FREO_EN-US_DV9', driveLetter: 'D', sizeRemaining: 50391 * MiB }
    ] }
  ] };
  let settings = { refreshOnFocus: false, showSystemPartitions: true, confirmDiscard: true,checkUpdatesAutomatically:false,closeProgressAutomatically:false,language:'en-US',updateFeed:'',notifications:{desktop:true,onSuccess:true,onError:true,email:false,sound:true},email:{host:'',port:587,tls:true,from:'',to:'',username:''} };
  return {
    inventory: async () => structuredClone(fixture),
    limits: async (target) => ({ sizeMin: 9 * GiB, sizeMax: fixture.disks.find((disk) => disk.number === target.diskNumber)?.partitions.find((partition) => partition.partitionNumber === target.partitionNumber)?.size || 57 * GiB }),
    apply: async () => { throw new Error('Real disk changes require the Windows desktop app.'); },
    check: async () => ({ message: 'UI preview — file system scans run in the desktop app.' }),
    getSettings: async () => settings,
    setSettings: async (value) => { settings = {...settings,...value,notifications:{...settings.notifications,...value.notifications},email:{...settings.email,...value.email}}; return settings; },
    capabilities:async()=>({windowsEdition:'UI preview',nativeVhd:true,adk:{available:false},v2vFormats:['vhd','vhdx']}),
    findOperatingSystems:async()=>({installations:[{sourceDrive:'C',caption:'Windows 11 (reference preview)'}]}),
    runTool:async()=>{throw new Error('This is a reference-data preview. Run the Windows desktop app to use this tool.');},
    choosePath:async()=>null,cancelJob:async()=>({requested:false}),
    getInfo:async()=>({pcId:'REFERENCE-PREVIEW-DEVICE',version:'20.0.0'}),copyText:async()=>{},openFolder:async()=>{},openExternal:async()=>{},
    getEmailState:async()=>({configured:false}),saveEmail:async(value)=>{settings.email={...settings.email,...value};delete settings.email.password;return settings;},
    testNotification:async()=>({message:'UI preview — desktop notifications run in the desktop app.'}),testEmail:async()=>({cancelled:true}),
    checkUpdates:async()=>({configured:false,available:false,message:'This local build has no published update feed. Configure a local or HTTPS release manifest in Application settings.'}),installUpdate:async()=>({cancelled:true}),cancelShutdown:async()=>({success:true}),
    getHistory: async () => [], exportDiagnostics: async () => ({ cancelled: true }), restartAsAdmin: async () => {}, windowControl: async () => {}, onProgress: () => () => {}
  };
}
