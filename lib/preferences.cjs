'use strict';
const defaults = Object.freeze({refreshOnFocus:true,showSystemPartitions:true,confirmDiscard:true,checkUpdatesAutomatically:true,closeProgressAutomatically:false,language:'en-US',updateFeed:'',notifications:{desktop:true,onSuccess:true,onError:true,email:false,sound:true},email:{host:'',port:587,tls:true,from:'',to:'',username:''}});
function sanitizeSettings(input={},previous={}) {
  const output={...defaults,...previous,notifications:{...defaults.notifications,...previous.notifications},email:{...defaults.email,...previous.email}};
  for(const key of ['refreshOnFocus','showSystemPartitions','confirmDiscard','checkUpdatesAutomatically','closeProgressAutomatically'])if(typeof input[key]==='boolean')output[key]=input[key];
  if(input.language!=null){if(!['en-US','en-GB'].includes(input.language))throw new Error('Choose a supported application language.');output.language=input.language;}
  if(input.updateFeed!=null){if(typeof input.updateFeed!=='string'||input.updateFeed.length>4096)throw new Error('Invalid update manifest location.');output.updateFeed=input.updateFeed.trim();}
  for(const key of Object.keys(defaults.notifications))if(typeof input.notifications?.[key]==='boolean')output.notifications[key]=input.notifications[key];
  for(const key of ['host','from','to','username'])if(input.email?.[key]!=null){if(typeof input.email[key]!=='string'||input.email[key].length>320||/[\r\n\0]/.test(input.email[key]))throw new Error('Invalid email setting.');output.email[key]=input.email[key].trim();}
  if(input.email?.port!=null){if(!Number.isInteger(input.email.port)||input.email.port<1||input.email.port>65535)throw new Error('SMTP port must be between 1 and 65535.');output.email.port=input.email.port;}
  if(typeof input.email?.tls==='boolean')output.email.tls=input.email.tls;
  delete output.email.password;delete output.email.passwordEncrypted;delete output.email.passwordConfigured;
  return output;
}
module.exports={defaults,sanitizeSettings};
