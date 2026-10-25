'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const versionParts = (version) => { if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(String(version))) throw new Error('Invalid update version.'); return version.split('-')[0].split('.').map(Number); };
function newer(candidate,current) { const a=versionParts(candidate),b=versionParts(current); for(let i=0;i<3;i++){if(a[i]!==b[i])return a[i]>b[i];}return false; }
async function checkUpdate(feed,currentVersion) {
  if (!feed) return { configured:false,available:false,message:'This local build has no published update feed. Choose a release manifest to check a maintained distribution.' };
  let raw;
  if (/^https:\/\//i.test(feed)) {
    const response=await fetch(feed,{signal:AbortSignal.timeout(15000),redirect:'error'});
    if(!response.ok)throw new Error('Update manifest could not be loaded: '+response.status);
    raw=await response.text();
  } else { if(!path.isAbsolute(feed))throw new Error('Choose an absolute local manifest path or an HTTPS update URL.');raw=await fs.readFile(feed,'utf8'); }
  if(raw.length>131072)throw new Error('The release manifest is too large.');
  const manifest=JSON.parse(raw);
  versionParts(manifest.version);
  if(!/^[a-f\d]{64}$/i.test(manifest.sha256 || ''))throw new Error('The update manifest needs a SHA-256 checksum.');
  if(typeof manifest.url!=='string'||(!/^https:\/\//i.test(manifest.url)&&!path.isAbsolute(manifest.url)))throw new Error('The update package must use HTTPS or an absolute local file path.');
  return {configured:true,available:newer(manifest.version,currentVersion),currentVersion,...manifest};
}
async function downloadUpdate(manifest,destination) {
  if(!/^[a-f\d]{64}$/i.test(manifest.sha256 || ''))throw new Error('Missing update checksum.');
  if(path.extname(destination).toLowerCase()!=='.exe')throw new Error('Choose a Windows .exe destination.');
  let data;
  if(/^https:\/\//i.test(manifest.url)){
    const response=await fetch(manifest.url,{signal:AbortSignal.timeout(300000),redirect:'error'});
    if(!response.ok)throw new Error('Update download failed: '+response.status);
    const chunks=[];let size=0;
    for await(const chunk of response.body){size+=chunk.length;if(size>1024**3)throw new Error('Update package exceeds 1 GiB.');chunks.push(Buffer.from(chunk));}
    data=Buffer.concat(chunks);
  }else{data=await fs.readFile(manifest.url);}
  if(crypto.createHash('sha256').update(data).digest('hex').toLowerCase()!==manifest.sha256.toLowerCase())throw new Error('Update checksum mismatch. The package was not saved or launched.');
  await fs.writeFile(destination,data,{flag:'wx'});
  return {path:destination,sha256:manifest.sha256,version:manifest.version};
}
module.exports={newer,checkUpdate,downloadUpdate};
