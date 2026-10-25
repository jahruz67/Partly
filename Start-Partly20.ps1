param([switch]$AsAdministrator)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if ($AsAdministrator) {
    $exe = Join-Path $PSScriptRoot 'node_modules/electron/dist/electron.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Install dependencies with pnpm install first.' }
    Start-Process -FilePath $exe -ArgumentList ('"' + $PSScriptRoot + '"') -Verb RunAs -WindowStyle Hidden
} else {
    & (Join-Path $PSScriptRoot 'node_modules/electron/dist/electron.exe') $PSScriptRoot
}
