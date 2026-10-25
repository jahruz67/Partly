'use strict';
const path=require('node:path');
function windowsPowerShellEnv() {
  // A PowerShell 7 parent exports a module search path that is incompatible with
  // Windows PowerShell 5.1. Use the native Windows modules for storage operations.
  const root=process.env.SystemRoot||'C:\\Windows';
  const modules=[path.join(root,'System32','WindowsPowerShell','v1.0','Modules'),path.join(process.env.ProgramFiles||'C:\\Program Files','WindowsPowerShell','Modules')];
  return {...process.env,PSModulePath:modules.join(';'),POWERSHELL_TELEMETRY_OPTOUT:'1'};
}
module.exports={windowsPowerShellEnv};
