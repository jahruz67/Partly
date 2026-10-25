# Loads only the file-manifest helpers. Never opens or formats a disk device.
$ErrorActionPreference='Stop'
$CancellationFile=$null
$workspaceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot=[IO.Path]::GetFullPath((Join-Path $workspaceRoot ('.reference\conversion-files-'+[guid]::NewGuid().ToString('N'))))
if(-not $fixtureRoot.StartsWith(($workspaceRoot.TrimEnd('\')+'\.reference\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path must stay inside the workspace reference folder.'}
New-Item -ItemType Directory -Path $fixtureRoot|Out-Null
try{
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $workspaceRoot 'windows\advanced-storage.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Advanced source did not parse.'}
    $names=@('Get-ConversionManifest','Assert-ConversionManifest','Copy-ConversionFiles')
    $functions=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names},$true))
    if($functions.Count -ne 3){throw 'Conversion fixture helper extraction failed.'}
    . ([scriptblock]::Create(($functions.Extent.Text -join "`n")))
    $source=Join-Path $fixtureRoot 'source';$staged=Join-Path $fixtureRoot 'staged'
    New-Item -ItemType Directory -Path $source,$staged,(Join-Path $source 'empty'),(Join-Path $source 'nested')|Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'one.txt'),'Conversion content verification fixture')
    [IO.File]::WriteAllBytes((Join-Path $source 'nested\binary.bin'),[byte[]]@(0,1,2,3,255))
    $before=Get-ConversionManifest ($source+'\') $true
    Copy-ConversionFiles $source $staged $false
    $copied=Get-ConversionManifest ($staged+'\')
    Assert-ConversionManifest $before $copied $false
    [IO.File]::WriteAllText((Join-Path $staged 'one.txt'),'tampered')
    $rejected=$false
    try{Assert-ConversionManifest $before (Get-ConversionManifest ($staged+'\')) $false}catch{$rejected=$true}
    if(-not $rejected){throw 'Tampered staged files were accepted.'}
    Set-Content -LiteralPath (Join-Path $source 'one.txt') -Stream 'extra' -Value 'Important alternate stream'
    $streamsRejected=$false
    try{Get-ConversionManifest ($source+'\') $true|Out-Null}catch{$streamsRejected=$true}
    if(-not $streamsRejected){throw 'Unsupported alternate streams were accepted.'}
    @{success=$true;copiedFiles=@($before.files).Count;emptyDirectoriesPreserved=$true;tamperingRejected=$rejected;alternateStreamsRejected=$streamsRejected;diskDeviceOpened=$false}|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}}
