'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const os=require('node:os');
const crypto=require('node:crypto');
const {sanitizeSettings}=require('../lib/preferences.cjs');
const {newer,checkUpdate,downloadUpdate}=require('../lib/update-service.cjs');

test('partial preference saves preserve notification flags and never persist a plaintext SMTP password',()=>{
  const previous=sanitizeSettings({notifications:{email:true,desktop:false},email:{host:'smtp.example.test',password:'never-save-this'}});
  const result=sanitizeSettings({notifications:{sound:false},closeProgressAutomatically:true},previous);
  assert.equal(result.notifications.email,true);assert.equal(result.notifications.desktop,false);assert.equal(result.notifications.sound,false);assert.equal(result.closeProgressAutomatically,true);
  assert.equal(result.email.host,'smtp.example.test');assert.equal(Object.hasOwn(result.email,'password'),false);
  assert.throws(()=>sanitizeSettings({email:{port:0}}),/port/);assert.throws(()=>sanitizeSettings({email:{host:'bad\r\nheader'}}),/Invalid/);assert.throws(()=>sanitizeSettings({language:'unknown'}),/supported/);
});
test('release version comparison uses numeric components and rejects unrecognized version strings',()=>{
  assert.equal(newer('1.10.0','1.9.9'),true);assert.equal(newer('1.1.0','1.1.0'),false);assert.equal(newer('1.0.99','1.1.0'),false);assert.throws(()=>newer('latest','1.0.0'),/version/);
});
test('unconfigured updates are reported honestly instead of claiming the app is up to date',async()=>{
  const result=await checkUpdate('','1.1.0');assert.equal(result.configured,false);assert.equal(result.available,false);assert.match(result.message,/no published update feed/);
});
test('local release packages are checksum verified and never overwrite an existing destination',async()=>{
  const directory=await fs.mkdtemp(path.join(os.tmpdir(),'partly20-update-fixture-'));
  try{
    const input=path.join(directory,'source.exe'),output=path.join(directory,'verified.exe'),manifestFile=path.join(directory,'release.json');
    const data=Buffer.from('DISPOSABLE TEST BYTES — THIS IS NOT EXECUTABLE SOFTWARE');await fs.writeFile(input,data);
    const manifest={version:'1.2.0',url:input,sha256:crypto.createHash('sha256').update(data).digest('hex')};await fs.writeFile(manifestFile,JSON.stringify(manifest));
    const checked=await checkUpdate(manifestFile,'1.1.0');assert.equal(checked.available,true);
    await downloadUpdate(checked,output);assert.deepEqual(await fs.readFile(output),data);
    await assert.rejects(downloadUpdate(checked,output),/exist|EEXIST/i);
    await assert.rejects(downloadUpdate({...manifest,sha256:'0'.repeat(64)},path.join(directory,'rejected.exe')),/checksum/);
    await assert.rejects(fs.access(path.join(directory,'rejected.exe')));
    await fs.writeFile(manifestFile,JSON.stringify({...manifest,sha256:'missing'}));await assert.rejects(checkUpdate(manifestFile,'1.1.0'),/checksum/);
  }finally{assert.ok(path.resolve(directory).startsWith(path.resolve(os.tmpdir())+path.sep));await fs.rm(directory,{recursive:true,force:true});}
});

test('Windows file-copy and ZIP diagnostics work with isolated file fixtures',{skip:process.platform!=='win32'},async()=>{
  const {runScript}=require('../lib/windows-command.cjs');
  const directory=await fs.mkdtemp(path.join(os.tmpdir(),'partly20-app-tool-fixture-'));
  try{
    const source=path.join(directory,'source.txt'),destination=path.join(directory,'copied');await fs.mkdir(destination);await fs.writeFile(source,'Disposable file-copy verification bytes.');
    const copied=await runScript('app-tools.ps1','copy-files',{sources:[source],destination,replaceExisting:false});assert.equal(copied.success,true);assert.deepEqual(await fs.readFile(path.join(destination,'source.txt')),await fs.readFile(source));
    await assert.rejects(runScript('app-tools.ps1','copy-files',{sources:[source],destination,replaceExisting:false}),/already contains/);
    const report=await runScript('app-tools.ps1','collect-logs',{destination:path.join(directory,'report.zip'),diagnostics:{testFixture:true},includeEvents:false,includeCrashDumps:false});assert.equal(report.success,true);assert.equal((await fs.readFile(report.path)).subarray(0,2).toString(),'PK');
  }finally{assert.ok(path.resolve(directory).startsWith(path.resolve(os.tmpdir())+path.sep));await fs.rm(directory,{recursive:true,force:true});}
});
