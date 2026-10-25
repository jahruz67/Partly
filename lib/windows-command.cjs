'use strict';
const {spawn} = require('node:child_process');
const fs = require('node:fs/promises');
const {existsSync} = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {windowsPowerShellEnv}=require('./windows-env.cjs');
async function runScript(scriptName, action, payload = {}, {onProgress, signal} = {}) {
  if (process.platform !== 'win32') throw new Error('This tool requires Windows.');
  if (!/^[a-z-]+\.ps1$/.test(scriptName)) throw new Error('Invalid application tool.');
  const resource = process.resourcesPath && path.join(process.resourcesPath,'windows',scriptName);
  const script = resource && existsSync(resource) ? resource : path.join(__dirname,'..','windows',scriptName);
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(),'partly20-tool-'));
  const requestFile = path.join(temporary,'request.json'), cancelPath = path.join(temporary,'cancel');
  const abort = () => { fs.writeFile(cancelPath,'cancel').catch(()=>{}); };
  try {
    await fs.writeFile(requestFile,JSON.stringify({...payload,cancelPath}),'utf8');
    signal?.addEventListener('abort',abort,{once:true});
    if (signal?.aborted) abort();
    return await new Promise((resolve,reject) => {
      const child = spawn(path.join(process.env.SystemRoot || 'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe'),['-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,'-Action',action,'-PayloadPath',requestFile],{windowsHide:true,shell:false,stdio:['ignore','pipe','pipe'],env:windowsPowerShellEnv()});
      let stdout='',stderr='',buffer='';
      child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
      child.stdout.on('data',chunk=>{stdout+=chunk;});
      child.stderr.on('data',chunk=>{stderr+=chunk;buffer+=chunk;let newline;while((newline=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,newline).trim();buffer=buffer.slice(newline+1);if(line.startsWith('PARTLY20_PROGRESS:')){try{onProgress?.(JSON.parse(line.slice(18)));}catch{}}}});
      child.on('error',reject);
      child.on('close',code=>{try{const result=JSON.parse(stdout.replace(/^\uFEFF/,'').trim());if(result.error)reject(new Error(result.error.message || result.error));else if(code && result.success !== false)reject(new Error(stderr.slice(-1500)||`Windows tool exited with ${code}.`));else resolve(result);}catch(error){reject(new Error('Windows tool failed: '+(stderr.trim()||error.message).slice(-2000)));}});
    });
  } finally {signal?.removeEventListener('abort',abort);await fs.rm(temporary,{recursive:true,force:true});}
}
module.exports={runScript};
