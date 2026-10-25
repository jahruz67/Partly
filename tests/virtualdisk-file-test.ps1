# Native VHD/VHDX round-trip smoke test. Creates only new image files; never attaches or formats a disk.
$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot ('.reference\virtualdisk-fixture-' + [guid]::NewGuid().ToString('N'))))
if (-not $fixtureRoot.StartsWith(($workspaceRoot.TrimEnd('\') + '\.reference\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture path must remain inside the workspace reference directory.' }
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $workspaceRoot 'windows\system-tools.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The system-tools source did not parse.' }
    $nativeSource = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'public static class Partly20VirtualDisk' }, $true))[0].Value
    Add-Type -TypeDefinition $nativeSource
    $source = Join-Path $fixtureRoot 'source.vhd'
    $destination = Join-Path $fixtureRoot 'converted.vhdx'
    $roundTrip = Join-Path $fixtureRoot 'roundtrip.vhd'
    $storage = New-Object 'Partly20VirtualDisk+StorageType'
    $storage.DeviceId = 2
    $storage.VendorId = [guid]'ec984aec-a0f9-47e9-901f-71415a66345b'
    $v2 = New-Object 'Partly20VirtualDisk+ParametersV2'
    $v2.UniqueId = [guid]::NewGuid(); $v2.MaximumSize = 8 * 1048576; $v2.SectorSize = 512
    $parameters = New-Object 'Partly20VirtualDisk+Parameters'
    $parameters.Version = 2; $parameters.V2 = $v2
    $arguments = [object[]]@($storage, $source, [uint32]0, [IntPtr]::Zero, [uint32]1, [uint32]0, $parameters, [IntPtr]::Zero, [IntPtr]::Zero)
    for ($argumentIndex = 0; $argumentIndex -lt $arguments.Length; $argumentIndex++) { $arguments[$argumentIndex] = $arguments[$argumentIndex].PSObject.BaseObject }
    $binding = [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
    $create = [Partly20VirtualDisk].GetMethod('CreateVirtualDisk', $binding)
    $code = $create.Invoke($null, $arguments)
    if ($code -ne 0) { throw "Could not create the disposable VHD fixture (Windows error $code)." }
    [Partly20VirtualDisk].GetMethod('CloseHandle', $binding).Invoke($null, @($arguments[8])) | Out-Null
    $pattern = [Text.Encoding]::UTF8.GetBytes('Partly 20 file-fixture round-trip data')
    $stream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($pattern, 0, $pattern.Length); $stream.Flush() } finally { $stream.Dispose() }
    $conversion = [Partly20VirtualDisk]::ConvertAsync($source, $destination, $false)
    $conversion.GetAwaiter().GetResult()
    $conversionBack = [Partly20VirtualDisk]::ConvertAsync($destination, $roundTrip, $true)
    $conversionBack.GetAwaiter().GetResult()
    $actual = New-Object byte[] $pattern.Length
    $read = [IO.File]::OpenRead($roundTrip)
    try { $count = $read.Read($actual, 0, $actual.Length) } finally { $read.Dispose() }
    if ($count -ne $pattern.Length -or [Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($pattern)) { throw 'Round-trip VHD contents differed from the original file fixture.' }
    [pscustomobject]@{ success = $true; conversion = 'fixed VHD -> dynamic VHDX -> fixed VHD'; contentVerified = $true; diskAttached = $false; sourceBytes = (Get-Item -LiteralPath $source).Length; vhdxBytes = (Get-Item -LiteralPath $destination).Length; roundTripBytes = (Get-Item -LiteralPath $roundTrip).Length } | ConvertTo-Json -Compress
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith(($workspaceRoot.TrimEnd('\') + '\.reference\'), [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedFixture).StartsWith('virtualdisk-fixture-')) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue }
}
