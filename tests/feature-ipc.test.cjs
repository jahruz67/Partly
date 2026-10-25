'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const Module=require('node:module');
const filename=path.resolve(__dirname,'../electron/feature-ipc.cjs');

function environment({confirm=0,tools={}}={}){
  const handlers=new Map(),calls=[],history=[];let busy=false;
  const electron={app:{getVersion:()=> '1.1.0',getPath:()=>process.cwd()},dialog:{showMessageBox:async(_window,options)=>{calls.push({kind:'confirm',options});return {response:confirm};}},clipboard:{writeText:()=>{}},Notification:{isSupported:()=>false},safeStorage:{isEncryptionAvailable:()=>false},shell:{openExternal:async(url)=>calls.push({kind:'external',url})}};
  const defaults={notifications:{desktop:false,email:false,onSuccess:false,onError:false}};
  const fresh=new Module(filename,module);fresh.filename=filename;fresh.paths=Module._nodeModulePaths(path.dirname(filename));
  const realRequire=Module.createRequire(filename);
  fresh.require=(id)=>id==='electron'?electron:id==='../lib/system-tools.cjs'?tools:id==='../lib/windows-command.cjs'?{runScript:async()=>{throw new Error('Unexpected Windows command during a memory-only test.');}}:realRequire(id);
  fresh._compile(fs.readFileSync(filename,'utf8'),filename);
  const features=fresh.exports.configureFeatures({handle:(name,fn)=>handlers.set(name,fn),getWindow:()=>({webContents:{send:()=>{}},isDestroyed:()=>false}),readJson:async(name,fallback)=>name==='settings.json'?defaults:name==='history.json'?[]:fallback,writeJson:async(name,value)=>history.push({name,value}),isBusy:()=>busy,setBusy:value=>{busy=value;}});
  return {handlers,calls,history,features,busy:()=>busy};
}
function payload(){const MiB=1024**2;return {expectedSnapshot:{isAdmin:true,disks:[{number:7,uniqueId:'ipc-fixture',size:128*MiB,partitionStyle:'GPT',partitions:[{partitionNumber:1,diskNumber:7,offset:MiB,size:32*MiB,driveLetter:'D',fileSystem:'NTFS',type:'Basic',label:'Fixture'}]}]},operations:[{id:'delete-fixture',type:'delete',diskNumber:7,diskUniqueId:'ipc-fixture',partitionNumber:1,partitionOffset:MiB,targetLabel:'Fixture (D:)',params:{}}],powerOffWhenComplete:true};}

test('native final cancellation is explicitly distinguished from a partially executed disk operation',async()=>{
  const env=environment({confirm:0});const result=await env.features.apply(payload());
  assert.deepEqual(result,{cancelled:true,beforeExecution:true});assert.equal(env.busy(),false);assert.equal(env.history.length,0);assert.match(env.calls[0].options.detail,/SHUT DOWN/);
});
test('tool installation receives explicit download authorization only after native confirmation',async()=>{
  let request;
  const env=environment({confirm:1,tools:{installDisk2vhd:async value=>{request=value;return {success:true,message:'fixture'};}}});
  await env.handlers.get('features:run')('install-disk2vhd',{destination:'C:\\fixture-only'});
  assert.equal(request.acceptDownload,true);assert.equal(env.busy(),false);assert.equal(env.history[0].name,'history.json');
  const denied=environment({confirm:0,tools:{installDisk2vhd:()=>{throw new Error('A cancelled install must never run.');}}});assert.deepEqual(await denied.handlers.get('features:run')('install-disk2vhd',{}),{cancelled:true});
});
test('external documentation opens only through the narrow HTTPS allowlist',async()=>{
  const env=environment();await assert.rejects(env.handlers.get('features:open-external')('https://untrusted.invalid/run.exe'),/not an allowed/);await assert.rejects(env.handlers.get('features:open-external')('file:///C:/Windows/system32/cmd.exe'),/not an allowed/);
  await env.handlers.get('features:open-external')('https://learn.microsoft.com/windows-hardware/get-started/adk-install');assert.equal(env.calls.length,1);assert.equal(env.calls[0].kind,'external');
});
