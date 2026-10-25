import test from 'node:test';
import assert from 'node:assert/strict';
import {validateOperation,projectInventory,MIB,GIB} from '../src/model.js';
const snapshot={isAdmin:true,disks:[{number:3,uniqueId:'convert-fixture',size:20*GIB,partitionStyle:'GPT',partitions:[{diskNumber:3,partitionNumber:1,offset:MIB,size:16*GIB,fileSystem:'NTFS',label:'Data',type:'Basic',driveLetter:'D',sizeRemaining:8*GIB}]}]};
const operation=params=>({id:'convert-test',type:'convert',diskNumber:3,diskUniqueId:'convert-fixture',partitionNumber:1,partitionOffset:MIB,params});
test('staged conversion requires recovery staging and explicit NTFS metadata acknowledgement',()=>{
  assert.match(validateOperation(operation({fileSystem:'exFAT',label:'Data'}),snapshot),/staging folder/);
  assert.match(validateOperation(operation({fileSystem:'exFAT',label:'Data',stagingDirectory:'C:\\stage'}),snapshot),/NTFS-only metadata/);
  const convert=operation({fileSystem:'exFAT',label:'Converted',stagingDirectory:'C:\\stage',allowMetadataChanges:true});assert.equal(validateOperation(convert,snapshot),null);const projected=projectInventory(snapshot,[convert]);assert.equal(projected.disks[0].partitions[0].fileSystem,'exFAT');assert.equal(projected.disks[0].partitions[0].label,'Converted');assert.equal(snapshot.disks[0].partitions[0].fileSystem,'NTFS');
});
test('same-filesystem conversion and unsupported FAT32 volume size are rejected before queue execution',()=>{
  assert.match(validateOperation(operation({fileSystem:'NTFS'}),snapshot),/different/);
  const larger=structuredClone(snapshot);larger.disks[0].size=64*GIB;larger.disks[0].partitions[0].size=48*GIB;
  assert.match(validateOperation(operation({fileSystem:'FAT32',label:'Data',stagingDirectory:'C:\\stage',allowMetadataChanges:true}),larger),/32 GB/);
});
test('native FAT32 to NTFS keeps the direct no-staging conversion path',()=>{
  const fat=structuredClone(snapshot);fat.disks[0].partitions[0].fileSystem='FAT32';assert.equal(validateOperation(operation({fileSystem:'NTFS'}),fat),null);
});
