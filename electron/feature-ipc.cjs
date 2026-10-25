'use strict';
const {app,dialog,clipboard,Notification,safeStorage,shell}=require('electron');
const fs=require('node:fs/promises');
const path=require('node:path');
const {runScript}=require('../lib/windows-command.cjs');
const {sanitizeSettings}=require('../lib/preferences.cjs');
const {executeBatch}=require('../lib/batch-service.cjs');
const updates=require('../lib/update-service.cjs');
const storage=require('../lib/storage-service.cjs');
const advanced=require('../lib/advanced-storage.cjs');
const recovery=require('../lib/recovery-storage.cjs');
const systemTools=require('../lib/system-tools.cjs');

function configureFeatures({handle,getWindow,readJson,writeJson,isBusy,setBusy}) {
  let controller=null;
  const progress=(value)=>{const window=getWindow();if(window&&!window.isDestroyed())window.webContents.send('storage:progress',value);};
  const getSettings=async()=>sanitizeSettings(await readJson('settings.json',{}));
  async function saveSettings(value){const result=sanitizeSettings(value,await getSettings());await writeJson('settings.json',result);return result;}
  async function emailCredentials(){const settings=await getSettings();const secret=await readJson('email-secret.json',null);return {...settings.email,password:secret&&safeStorage.isEncryptionAvailable()?safeStorage.decryptString(Buffer.from(secret.encrypted,'base64')):''};}
  function showDesktopNotification(options){
    if(!Notification.isSupported())return Promise.reject(new Error('Windows desktop notifications are not available.'));
    return new Promise((resolve,reject)=>{const notification=new Notification(options);const timeout=setTimeout(()=>reject(new Error('Windows did not confirm that the notification was displayed. Check Windows notification settings.')),10000);notification.once('show',()=>{clearTimeout(timeout);resolve();});notification.once('failed',(_event,error)=>{clearTimeout(timeout);reject(new Error(error||'Windows rejected the notification.'));});notification.show();});
  }
  async function notify(title,body,failed=false){
    const settings=await getSettings();
    if(failed&&!settings.notifications.onError||!failed&&!settings.notifications.onSuccess)return;
    if(settings.notifications.desktop)await showDesktopNotification({title,body,silent:!settings.notifications.sound}).catch(error=>progress({message:'Desktop notification: '+error.message,notificationError:true}));
    if(settings.notifications.email)await runScript('app-tools.ps1','send-email',{smtp:await emailCredentials(),subject:title,body}).catch(error=>progress({message:'Email notification failed: '+error.message,notificationError:true}));
  }
  async function confirm(title,detail,button='Continue'){
    const result=await dialog.showMessageBox(getWindow(),{type:'warning',title:'Partly 20 — '+title,message:title,detail,buttons:['Cancel',button],defaultId:0,cancelId:0,noLink:true});
    return result.response===1;
  }
  async function history(record){const list=await readJson('history.json',[]);list.unshift({...record,finishedAt:new Date().toISOString()});await writeJson('history.json',list.slice(0,100));}
  async function runJob(title,operation,fn){
    if(isBusy())throw new Error('Wait for the current operation to finish.');
    setBusy(true);controller=new AbortController();
    const record={id:Date.now().toString(36),startedAt:new Date().toISOString(),operations:Array.isArray(operation)?operation:[{type:operation,targetLabel:title,params:{}}]};
    try{
      const result=await fn(controller.signal);
      record.status=result.success===false||result.cancelled?'stopped':'completed';record.result=result;
      await notify('Partly 20 — '+title,result.message||(result.cancelled?'Operation cancelled.':'Operation completed.'),result.success===false);
      return result;
    }catch(error){record.status='failed';record.error=error.message;await notify('Partly 20 — Operation stopped',error.message,true);if(error.result)return {...error.result,success:false,message:error.message};throw error;}
    finally{controller=null;setBusy(false);await history(record).catch(()=>{});}
  }
  handle('features:cancel',()=>{if(!controller)return {requested:false};controller.abort();progress({message:'Cancellation requested. Waiting for a safe stopping point.',cancellable:false});return {requested:true};});
  handle('features:choose-path',async(options={})=>{
    const common={title:String(options.title||'Choose a location').slice(0,200)};
    if(options.save){const result=await dialog.showSaveDialog(getWindow(),{...common,defaultPath:typeof options.defaultPath==='string'?options.defaultPath:undefined,filters:Array.isArray(options.filters)?options.filters:undefined});return result.canceled?null:result.filePath;}
    const result=await dialog.showOpenDialog(getWindow(),{...common,properties:options.directory?['openDirectory','createDirectory']:['openFile',...(options.multiple?['multiSelections']:[])],filters:Array.isArray(options.filters)?options.filters:undefined});
    return result.canceled?null:options.multiple?result.filePaths:result.filePaths[0];
  });
  handle('features:capabilities',()=>systemTools.getCapabilities());
  handle('features:find-os',()=>systemTools.findOperatingSystems());
  handle('features:info',async()=>({...await runScript('app-tools.ps1','info'),version:app.getVersion(),license:'Local edition — no account or expiration'}));
  handle('features:copy-text',(text)=>{if(typeof text!=='string'||text.length>100000)throw new Error('Invalid clipboard text.');clipboard.writeText(text);return true;});
  handle('features:open-external',async(url)=>{const target=new URL(url);if(target.protocol!=='https:'||!['learn.microsoft.com','www.microsoft.com','www.qemu.org','qemu.org'].includes(target.hostname))throw new Error('This external link is not an allowed documentation site.');await shell.openExternal(target.href);return true;});
  handle('features:open-folder',async(file)=>{if(typeof file!=='string'||!path.isAbsolute(file))throw new Error('Choose an absolute local path.');await fs.access(file);shell.showItemInFolder(file);return true;});
  handle('features:email-state',async()=>({configured:Boolean(await readJson('email-secret.json',null))}));
  handle('features:save-email',async(value)=>{
    const settings=await saveSettings({email:value});
    if(typeof value.password==='string'&&value.password){if(!safeStorage.isEncryptionAvailable())throw new Error('Windows credential encryption is unavailable. The password was not saved.');await writeJson('email-secret.json',{encrypted:safeStorage.encryptString(value.password).toString('base64')});}
    if(value.removePassword)await fs.rm(path.join(app.getPath('userData'),'email-secret.json'),{force:true});
    return settings;
  });
  handle('features:test-notification',async()=>{await showDesktopNotification({title:'Partly 20',body:'Desktop notifications are working.'});return {success:true,message:'Test notification displayed by Windows.'};});
  handle('features:test-email',async()=>{
    const smtp=await emailCredentials();
    if(!await confirm('Send test email?',`Send a Partly 20 test message from ${smtp.from} to ${smtp.to} through ${smtp.host}?`,'Send test'))return {cancelled:true};
    return runScript('app-tools.ps1','send-email',{smtp,subject:'Partly 20 — Test notification',body:'This test confirms your Partly 20 email notification settings.'});
  });
  handle('features:check-updates',async()=>updates.checkUpdate((await getSettings()).updateFeed,app.getVersion()));
  handle('features:install-update',async()=>{
    if(isBusy())throw new Error('Wait for current disk operations to finish.');
    const manifest=await updates.checkUpdate((await getSettings()).updateFeed,app.getVersion());
    if(!manifest.available)return manifest;
    const result=await dialog.showSaveDialog(getWindow(),{title:'Save Partly 20 update',defaultPath:`Partly-20-${manifest.version}-Windows.exe`,filters:[{name:'Windows executable',extensions:['exe']}]});
    if(result.canceled)return {cancelled:true};
    const downloaded=await updates.downloadUpdate(manifest,result.filePath);
    if(!await confirm('Launch the downloaded update?',`Source: ${manifest.url}\n\nThe SHA-256 checksum matches the release manifest you selected. Only launch this executable if you trust that source.\n\n${downloaded.path}\n\nPartly 20 will close before launching the update.`,'Launch update'))return downloaded;
    app.releaseSingleInstanceLock();
    const error=await shell.openPath(downloaded.path);if(error){app.requestSingleInstanceLock();throw new Error(error);}app.quit();return downloaded;
  });
  handle('features:run',async(action,payload={})=>{
    const names={check:'Check file system',surface:'Test surface',sectors:'Read sectors','write-sectors':'Write sectors',undelete:'Search for lost volumes',recover:'Recover volume','copy-files':'Copy files and folders',backup:'Backup',restore:'Restore backup',migration:'V2V Migration','copy-os':'Copy operating system',media:'Recovery Media Builder','list-backups':'Find backups',logs:'Collect log files','install-disk2vhd':'Install Microsoft Disk2vhd'};
    if(!Object.hasOwn(names,action))throw new Error('Unknown application tool.');
    if(['sectors','list-backups'].includes(action))return action==='sectors'?advanced.execute('readSectors',payload):systemTools.listBackups(payload);
    const confirmations={
      'write-sectors':'Write raw sector bytes to the selected data partition? A byte-for-byte backup will be saved before writing. Incorrect sector values can make files unreadable.',
      recover:'Restore the selected lost-volume partition entry? The existing file system will not be formatted.',
      restore:'Restore this image to the selected destination volume? Existing destination files may be replaced.',
      'copy-os':'Copy Windows to the selected empty target disk and create its boot partitions? The source disk will remain intact.',
      media:payload.kind==='native'?null:payload.kind==='usb'?'Create recovery media on this USB disk? Its media partitions will be written by Windows PE tools.':null,
      'copy-files':payload.replaceExisting?'Copy the selected files and replace matching destination files?':null,
      'install-disk2vhd':'Download Microsoft Disk2vhd from Microsoft Sysinternals? Its license must be reviewed and accepted separately before use.'
    };
    if(confirmations[action]&&!await confirm(names[action],confirmations[action]))return {cancelled:true};
    if(action==='install-disk2vhd')payload={...payload,acceptDownload:true};
    if(action==='migration'&&payload.acceptEula&&!await confirm('Microsoft Disk2vhd license', 'You selected acceptance of the Microsoft Sysinternals Disk2vhd license. Continue only if you have reviewed and agree to its terms.','Accept and continue'))return {cancelled:true};
    return runJob(names[action],action,async(signal)=>{
      const options={onProgress:progress,signal};
      switch(action){
        case 'check':return storage.checkPartition(payload.target,signal);
        case 'surface':return advanced.execute('surfaceScan',payload,options);
        case 'write-sectors':return advanced.execute('writeSectors',payload,options);
        case 'undelete':return recovery.scanLostVolumes(payload,progress,signal);
        case 'recover':return recovery.recoverVolume(payload,progress,signal);
        case 'copy-files':return runScript('app-tools.ps1','copy-files',payload,options);
        case 'logs':return runScript('app-tools.ps1','collect-logs',{...payload,crashDirectory:app.getPath('crashDumps'),diagnostics:{app:'Partly 20',version:app.getVersion(),inventory:await storage.getInventory(),history:await readJson('history.json',[])}},options);
        case 'backup':return systemTools.backup(payload,progress,signal);
        case 'restore':return systemTools.restore(payload,progress,signal);
        case 'migration':return systemTools.migrate(payload,progress,signal);
        case 'copy-os':return systemTools.copyOperatingSystem(payload,progress,signal);
        case 'media':return systemTools.createRecoveryMedia(payload,progress,signal);
        case 'install-disk2vhd':return systemTools.installDisk2vhd(payload,progress,signal);
      }
    });
  });
  handle('features:cancel-shutdown',()=>runScript('app-tools.ps1','cancel-shutdown'));
  async function apply(payload){
    if(isBusy())throw new Error('Wait for the current operation to finish.');
    if(!payload||!Array.isArray(payload.operations)||!payload.operations.length)throw new Error('The operation queue is empty.');
    const {validateOperation,describeOperation}=await import('../src/model.js');
    for(let i=0;i<payload.operations.length;i++){const error=validateOperation(payload.operations[i],payload.expectedSnapshot,payload.operations.slice(0,i));if(error)throw new Error(error);}
    const detail=payload.operations.map((operation,index)=>`${index+1}. ${describeOperation(operation)}`).join('\n')+'\n\nThese changes affect real Windows disks. Formatting and deletion remove data.'+(payload.powerOffWhenComplete?'\n\nWindows will SHUT DOWN 60 seconds after every operation succeeds.':'');
    if(!await confirm(`Apply ${payload.operations.length} disk operation${payload.operations.length===1?'':'s'}?`,detail,'Apply changes'))return {cancelled:true,beforeExecution:true};
    const result=await runJob('Disk operations',payload.operations,(signal)=>executeBatch(payload,{storage,advanced,onProgress:progress,signal}));
    if(result.success&&payload.powerOffWhenComplete){await runScript('app-tools.ps1','shutdown');result.shutdownScheduled=true;}
    return result;
  }
  return {apply,getSettings,saveSettings};
}
module.exports={configureFeatures};
