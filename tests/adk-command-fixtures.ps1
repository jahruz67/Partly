# Tests only harmless local batch fixtures, never any installed ADK or storage command.
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root=[IO.Path]::GetFullPath((Join-Path $workspace ('.reference\ADK fixture (x86)-'+[guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith(($workspace.TrimEnd('\')+'\.reference\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture must stay in the workspace reference directory.'}
New-Item -ItemType Directory -Path $root|Out-Null
try{
    $tokens=$null;$errors=$null;$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $workspace 'windows\system-tools.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'System tools did not parse.'}
    $function=$ast.Find({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AdkCommand'},$true)
    . ([scriptblock]::Create($function.Extent.Text))
    function Write-ProgressEvent($Message,$Percent,$Cancellable){}
    $environment=Join-Path $root 'Environment setup.bat';$tool=Join-Path $root 'Media tool.cmd'
    @('@echo off','set "PARTLY20_FIXTURE_ENV=ready"','exit /b 0')|Set-Content -LiteralPath $environment -Encoding ASCII
    @('@echo off','if not "%PARTLY20_FIXTURE_ENV%"=="ready" exit /b 11','if not "%~1"=="amd64" exit /b 12','if not "%~2"=="path with (parentheses)" exit /b 13','echo ADK_QUOTING_VERIFIED','exit /b 0')|Set-Content -LiteralPath $tool -Encoding ASCII
    $output=Invoke-AdkCommand @{environment=$environment} $tool @('amd64','path with (parentheses)')
    if($output -notmatch 'ADK_QUOTING_VERIFIED'){throw 'ADK argument quoting did not preserve the paths.'}
    $blocked=$false
    try{Invoke-AdkCommand @{environment=$environment} $tool @('amd64','%COMSPEC%')|Out-Null}catch{$blocked=$true}
    if(-not $blocked){throw 'Command expansion tokens were accepted.'}
    @{success=$true;spacesAndParenthesesVerified=$true;commandExpansionBlocked=$blocked;installedAdkRun=$false;diskChanged=$false}|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
