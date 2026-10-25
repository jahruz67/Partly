param(
    [Parameter(Mandatory = $true)][ValidateSet('capabilities', 'backup', 'listBackups', 'restore', 'migrate', 'downloadDisk2vhd', 'recoveryMedia', 'findOperatingSystems', 'copyOperatingSystem')][string]$Action,
    [Parameter(Mandatory = $true)][string]$PayloadPath,
    [string]$CancelPath
)

# All user values arrive as JSON data. No caller-supplied command strings are executed.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:StartedWriting = $false
$script:Artifacts = New-Object 'System.Collections.Generic.List[string]'
$script:RecoveryDetails = @{}

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-Administrator { if (-not (Test-Administrator)) { throw 'Restart Partly 20 as administrator to use this tool.' } }
function Write-ProgressEvent($Message, [int]$Percent = -1, [bool]$CanCancel = $true) {
    [Console]::Error.WriteLine('PARTLY20_PROGRESS:' + (@{ message = $Message; percent = $(if ($Percent -ge 0) { $Percent } else { $null }); canCancel = $CanCancel; cancellable = $CanCancel; action = $Action } | ConvertTo-Json -Compress))
}
function Assert-NotCancelled { if ($CancelPath -and (Test-Path -LiteralPath $CancelPath)) { throw (New-Object OperationCanceledException('Cancelled before the next operation.')) } }
function Get-DriveLetter($Value) {
    if ([string]$Value -notmatch '^[A-Za-z]:?\\?$') { throw 'Select a Windows volume by its drive letter.' }
    return ([string]$Value).Substring(0, 1).ToUpperInvariant()
}
function Get-AbsolutePath($Value) {
    $valueString = [string]$Value
    if ([string]::IsNullOrWhiteSpace($valueString) -or $valueString -match '[\x00-\x1f"<>|]' -or $valueString -match '^\\\\[.?]\\' -or -not [IO.Path]::IsPathRooted($valueString)) { throw 'Select an absolute Windows file or folder path.' }
    return [IO.Path]::GetFullPath($valueString)
}
function Assert-NewOutput($Value, $Extension) {
    $full = Get-AbsolutePath $Value
    if ([IO.Path]::GetExtension($full) -notmatch $Extension) { throw 'The destination file extension does not match the requested output.' }
    if (Test-Path -LiteralPath $full) { throw 'The destination already exists. Choose a new filename so existing data is preserved.' }
    $parent = [IO.Path]::GetDirectoryName($full)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'The destination folder does not exist.' }
    return $full
}
function Get-ToolPath($Name) { $command = Get-Command $Name -ErrorAction SilentlyContinue; if ($command) { return [string]$command.Source }; return $null }
function Get-Disk2vhdPath {
    $default = Join-Path $env:LOCALAPPDATA 'Partly20\Tools\Disk2vhd\disk2vhd64.exe'
    if (Test-Path -LiteralPath $default) { return $default }
    $command = Get-ToolPath 'disk2vhd64.exe'
    if (-not $command) { $command = Get-ToolPath 'disk2vhd.exe' }
    return $command
}
function Find-Adk {
    $roots = @((Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit'), (Join-Path $env:ProgramFiles 'Windows Kits\10\Assessment and Deployment Kit')) | Select-Object -Unique
    foreach ($root in $roots) {
        $pe = Join-Path $root 'Windows Preinstallation Environment'
        $copype = Join-Path $pe 'copype.cmd'
        $media = Join-Path $pe 'MakeWinPEMedia.cmd'
        $environment = Join-Path $root 'Deployment Tools\DandISetEnv.bat'
        if ((Test-Path -LiteralPath $copype) -and (Test-Path -LiteralPath $media) -and (Test-Path -LiteralPath $environment)) { return @{ available = $true; copype = $copype; makeWinPEMedia = $media; environment = $environment; root = $root } }
    }
    return @{ available = $false; copype = $null; makeWinPEMedia = $null; environment = $null; installationUrl = 'https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install' }
}
function Get-Capabilities {
    $wbadmin = Get-ToolPath 'wbadmin.exe'
    $wbHelp = if ($wbadmin) { (& $wbadmin '/?' 2>&1 | Out-String) } else { '' }
    $qemu = Get-ToolPath 'qemu-img.exe'
    if (-not $qemu) { $candidate = Join-Path $env:ProgramFiles 'qemu\qemu-img.exe'; if (Test-Path -LiteralPath $candidate) { $qemu = $candidate } }
    $hyperV = [bool](Get-Command Convert-VHD -ErrorAction SilentlyContinue)
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $nativeVhd = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\virtdisk.dll')
    $formats = @('vhd', 'vhdx'); if ($qemu) { $formats = @('vhd', 'vhdx', 'vmdk', 'vdi', 'qcow2') }
    return @{ isAdmin = Test-Administrator; windowsEdition = [string]$osInfo.Caption; windowsVersion = [string]$osInfo.Version; wbadmin = $wbadmin; supportsWbadminRecovery = [bool]($wbHelp -match 'START\s+RECOVERY'); dism = Get-ToolPath 'dism.exe'; recoveryDrive = Get-ToolPath 'RecoveryDrive.exe'; adk = Find-Adk; disk2vhd = Get-Disk2vhdPath; nativeVhd = [bool]$nativeVhd; convertVhd = $hyperV; qemuImg = $qemu; supportsWimBackup = [bool](Get-ToolPath 'dism.exe'); disk2vhdLicenseUrl = 'https://learn.microsoft.com/en-us/sysinternals/license-terms'; disk2vhdDownloadUrl = 'https://download.sysinternals.com/files/Disk2vhd.zip'; v2vFormats = $formats }
}
function Quote-Argument([string]$Value) {
    # Windows CommandLineToArgvW quoting; no shell is involved for executable tools.
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Invoke-Native([string]$Executable, [string[]]$Arguments, [bool]$Cancellable = $true) {
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "Required Windows tool was not found: $Executable" }
    if (-not $script:StartedWriting) { Assert-NotCancelled }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Windows could not start the requested tool.' }
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $lastMessage = [DateTime]::UtcNow
    while (-not $process.WaitForExit(300)) {
        if ($Cancellable -and $CancelPath -and (Test-Path -LiteralPath $CancelPath)) {
            $process.Kill(); $process.WaitForExit(); throw (New-Object OperationCanceledException('The operation was cancelled. Any incomplete output is preserved for inspection.'))
        }
        if (([DateTime]::UtcNow - $lastMessage).TotalSeconds -ge 4) { Write-ProgressEvent ('Windows is running ' + [IO.Path]::GetFileNameWithoutExtension($Executable) + '...') -1 $Cancellable; $lastMessage = [DateTime]::UtcNow }
    }
    $text = $stdout.Result + "`n" + $stderr.Result
    $exitCode = $process.ExitCode; $process.Dispose()
    if ($exitCode -ne 0) { throw ([IO.Path]::GetFileName($Executable) + " failed (exit $exitCode). " + $text.Trim().Substring(0, [Math]::Min(4000, $text.Trim().Length))) }
    return $text.Trim()
}
function Get-BackupDestination($Value) {
    $destination = [string]$Value
    if ($destination -match '^[A-Za-z]:\\?$') { return (Get-DriveLetter $destination) + ':' }
    if ($destination -match '^\\\\[^\\/]+\\[^\\/]+') { return Get-AbsolutePath $destination }
    throw 'Select a drive root or network share for Windows system-image backup.'
}
function Get-TargetPartition($Target) {
    if ($null -eq $Target -or [string]::IsNullOrWhiteSpace([string]$Target.diskUniqueId)) { throw 'The destination disk identity is required.' }
    $disk = Get-Disk -Number ([int]$Target.diskNumber) -ErrorAction Stop
    if ([string]$disk.UniqueId -cne [string]$Target.diskUniqueId) { throw 'Destination disk identity changed. Refresh the disk list.' }
    if ($disk.IsOffline -or $disk.IsReadOnly -or [string]$disk.HealthStatus -ne 'Healthy' -or [string]$disk.BusType -eq 'Spaces' -or $disk.IsClustered) { throw 'The destination disk is offline, read-only, unhealthy, or managed by another storage service.' }
    $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber ([int]$Target.partitionNumber) -ErrorAction Stop
    if ([long]$partition.Offset -ne [long]$Target.partitionOffset) { throw 'Destination partition location changed. Refresh the disk list.' }
    $gpt = ([string]$partition.GptType).Trim('{}').ToLowerInvariant()
    if ($partition.IsBoot -or $partition.IsSystem -or $partition.IsReadOnly -or ([string]$partition.DriveLetter + ':') -eq $env:SystemDrive -or ($gpt -and $gpt -ne 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7') -or [string]$partition.Type -match 'Recovery|Reserved|System') { throw 'Windows, recovery, reserved, and read-only partitions cannot be used as restore targets.' }
    $volume = @($partition | Get-Volume -ErrorAction Stop)[0]
    Assert-Decrypted $volume
    return $partition
}
function Assert-Decrypted($Volume) {
    if ($null -eq $Volume) { throw 'The volume is inaccessible.' }
    try {
        $items = @(Get-CimInstance -Namespace 'Root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop)
        $match = @($items | Where-Object { ([string]$_.DeviceID).TrimEnd('\') -eq ([string]$Volume.Path).TrimEnd('\') -or ([string]$_.DriveLetter -and [string]$_.DriveLetter -eq ([string]$Volume.DriveLetter + ':')) })
        if ($match.Count) {
            $lock = Invoke-CimMethod -InputObject $match[0] -MethodName GetLockStatus -ErrorAction Stop
            $conversion = Invoke-CimMethod -InputObject $match[0] -MethodName GetConversionStatus -ErrorAction Stop
            if ($lock.ReturnValue -ne 0 -or $lock.LockStatus -ne 0 -or $conversion.ReturnValue -ne 0 -or $conversion.ConversionStatus -ne 0) { throw 'The volume must be unlocked and fully decrypted before imaging or recovery.' }
        }
    } catch { throw ('Windows could not verify a fully decrypted volume. ' + $_.Exception.Message) }
}
function Find-OperatingSystems {
    $systems = @(foreach ($volume in @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.FileSystemType -eq 'NTFS' })) {
        $letter = [string]$volume.DriveLetter
        $root = $letter + ':\'
        if ((Test-Path -LiteralPath (Join-Path $root 'Windows\System32\config\SYSTEM')) -and (Test-Path -LiteralPath (Join-Path $root 'Windows\System32\winload.efi'))) {
            $partition = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)[0]; $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
            $product = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $root 'Windows\System32\kernel32.dll'))
            @{ sourceDrive = $letter; windowsPath = (Join-Path $root 'Windows'); version = [string]$product.ProductVersion; label = [string]$volume.FileSystemLabel; diskNumber = [int]$disk.Number; diskUniqueId = [string]$disk.UniqueId; partitionNumber = [int]$partition.PartitionNumber; partitionOffset = [long]$partition.Offset; current = (($letter + ':') -eq $env:SystemDrive); size = [long]$volume.Size; sizeRemaining = [long]$volume.SizeRemaining }
        }
    })
    return @{ systems = $systems; installations = $systems }
}
function New-WimBackup($SourceDrive, $ImagePath) {
    Assert-Administrator; Assert-NotCancelled
    $letter = Get-DriveLetter $SourceDrive
    $sourceRoot = $letter + ':\'
    $image = Assert-NewOutput $ImagePath '^\.wim$'
    if ([IO.Path]::GetPathRoot($image).TrimEnd('\') -eq ($letter + ':')) { throw 'The backup image must be saved outside the source volume.' }
    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    if ([string]$volume.FileSystemType -ne 'NTFS') { throw 'Consistent WIM snapshots require an NTFS source volume. Use Windows system-image backup for other supported volumes.' }
    Assert-Decrypted $volume
    $partition = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)[0]; $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    $imageVolumeLetter = [IO.Path]::GetPathRoot($image).Substring(0, 1)
    if ($image -match '^[A-Za-z]:\\') {
        $destinationVolume = Get-Volume -DriveLetter $imageVolumeLetter -ErrorAction Stop
        if ([long]$destinationVolume.SizeRemaining -lt ([long]$volume.Size - [long]$volume.SizeRemaining + 1073741824)) { throw 'The image destination needs enough free space for the used source data plus 1 GiB.' }
    }
    $shadow = $null; $linkPath = Join-Path ([IO.Path]::GetTempPath()) ('partly20-shadow-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-ProgressEvent 'Creating a consistent Volume Shadow Copy snapshot...' 2
        $create = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = $sourceRoot; Context = 'ClientAccessible' } -ErrorAction Stop
        if ($create.ReturnValue -ne 0) { throw "Windows could not create the source snapshot (VSS result $($create.ReturnValue))." }
        $shadow = Get-CimInstance Win32_ShadowCopy -Filter ("ID='" + [string]$create.ShadowID + "'") -ErrorAction Stop
        if (-not ('Partly20SnapshotLink' -as [type])) {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Partly20SnapshotLink { [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateSymbolicLink(string link,string target,int flags); [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool RemoveDirectory(string path); }'
        }
        if (-not [Partly20SnapshotLink]::CreateSymbolicLink($linkPath, ([string]$shadow.DeviceObject + '\'), 1)) { throw 'Windows could not expose the read-only snapshot to the image capture tool.' }
        Assert-NotCancelled
        $script:Artifacts.Add($image)
        Write-ProgressEvent 'Capturing the snapshot to a verified WIM image...' 8
        $output = Invoke-Native (Get-ToolPath 'dism.exe') @('/English', '/Capture-Image', ('/ImageFile:' + $image), ('/CaptureDir:' + $linkPath + '\'), '/Name:Partly 20 backup', '/Compress:fast', '/CheckIntegrity', '/Verify', '/EA') $true
        $manifest = @{ format = 'Partly20.WimBackup'; schemaVersion = 1; createdAt = [DateTime]::UtcNow.ToString('o'); imagePath = $image; sourceDrive = $letter; sourceDiskUniqueId = [string]$disk.UniqueId; sourcePartitionOffset = [long]$partition.Offset; sourceSize = [long]$partition.Size; usedBytes = [long]$volume.Size - [long]$volume.SizeRemaining; fileSystem = [string]$volume.FileSystemType; label = [string]$volume.FileSystemLabel; imageSize = (Get-Item -LiteralPath $image).Length; index = 1; consistentSnapshot = $true; snapshotContext = 'ClientAccessible'; machine = $env:COMPUTERNAME }
        $manifestPath = $image + '.partly.json'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $script:Artifacts.Add($manifestPath)
        Write-ProgressEvent 'Backup image completed.' 100
        return @{ success = $true; message = 'A consistent WIM backup was created.'; imagePath = $image; manifestPath = $manifestPath; manifest = $manifest; output = $output }
    } finally {
        if (Test-Path -LiteralPath $linkPath) { if ('Partly20SnapshotLink' -as [type]) { [Partly20SnapshotLink]::RemoveDirectory($linkPath) | Out-Null } }
        if ($shadow) { Remove-CimInstance -InputObject $shadow -ErrorAction SilentlyContinue }
    }
}
function Invoke-WindowsBackup($Request) {
    Assert-Administrator
    $destination = Get-BackupDestination $Request.destination
    $letters = @($Request.sourceDrives | ForEach-Object { Get-DriveLetter $_ } | Select-Object -Unique)
    if ($letters.Count -lt 1) { throw 'Choose at least one source volume.' }
    foreach ($letter in $letters) { Get-Volume -DriveLetter $letter -ErrorAction Stop | Out-Null }
    if ($destination -match '^[A-Z]:$' -and $letters -contains $destination.Substring(0, 1)) { throw 'The backup destination cannot also be a source volume.' }
    $executable = Get-ToolPath 'wbadmin.exe'; if (-not $executable) { throw 'Windows system-image backup is not installed on this Windows edition.' }
    $args = @('start', 'backup', ('-backupTarget:' + $destination), ('-include:' + (($letters | ForEach-Object { $_ + ':' }) -join ',')), '-vssCopy', '-quiet')
    if ($Request.includeSystem) { $args += '-allCritical' }
    Write-ProgressEvent 'Windows is creating a system-image backup...' 0 $false
    $text = Invoke-Native $executable $args $false
    return @{ success = $true; message = 'Windows system-image backup completed.'; output = $text; destination = $destination }
}
function Get-Backups($Request) {
    Assert-Administrator
    $images = @()
    if ($Request.destination) {
        $directory = Get-AbsolutePath ($(if ([string]$Request.destination -match '^[A-Za-z]:$') { [string]$Request.destination + '\' } else { $Request.destination }))
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'The backup location does not exist.' }
        $images = @(Get-ChildItem -LiteralPath $directory -Filter '*.partly.json' -File -ErrorAction Stop | ForEach-Object {
            try {
                $manifest = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $adjacentImage = $_.FullName.Substring(0, $_.FullName.Length - '.partly.json'.Length)
                if (Test-Path -LiteralPath $adjacentImage -PathType Leaf) { $manifest.imagePath = $adjacentImage }
                if ($manifest.format -eq 'Partly20.WimBackup' -and (Test-Path -LiteralPath $manifest.imagePath -PathType Leaf)) { $manifest }
            } catch { }
        })
    }
    $text = ''; $versions = @(); $wbError = $null
    $wbadmin = Get-ToolPath 'wbadmin.exe'
    if ($wbadmin) {
        $args = @('get', 'versions')
        if ($Request.destination -and ([string]$Request.destination -match '^[A-Za-z]:\\?$' -or [string]$Request.destination -match '^\\\\')) { $args += ('-backupTarget:' + (Get-BackupDestination $Request.destination)); $args += ('-machine:' + $env:COMPUTERNAME) }
        try { $text = Invoke-Native $wbadmin $args; $versions = @([regex]::Matches($text, '\b\d{2}/\d{2}/\d{4}-\d{2}:\d{2}\b') | ForEach-Object { $_.Value } | Select-Object -Unique) } catch { $wbError = $_.Exception.Message }
    }
    return @{ success = $true; images = $images; versions = $versions; output = $text; windowsBackupError = $wbError }
}
function Restore-Wim($Request) {
    Assert-Administrator; Assert-NotCancelled
    $image = Get-AbsolutePath $Request.imagePath
    $index = if ($null -ne $Request.index) { [int]$Request.index } else { 1 }
    if ($index -lt 1 -or $index -gt 65535) { throw 'Choose a positive WIM image index.' }
    if (-not (Test-Path -LiteralPath $image -PathType Leaf) -or [IO.Path]::GetExtension($image) -ne '.wim') { throw 'Select an existing WIM backup image.' }
    $partition = Get-TargetPartition $Request.target
    $letter = Get-DriveLetter $Request.destinationDrive
    if ([string]$partition.DriveLetter -cne $letter) { throw 'The restore drive letter no longer identifies the reviewed destination partition.' }
    $root = $letter + ':\'
    if ([IO.Path]::GetPathRoot($image).TrimEnd('\') -eq ($letter + ':')) { throw 'The backup image cannot be stored on the restore destination.' }
    $entries = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop | Where-Object { $_.Name -notin @('System Volume Information', '$RECYCLE.BIN') })
    if ($entries.Count) { throw 'WIM recovery requires an empty destination volume. Format the selected data volume in the reviewed operation queue first, then retry recovery.' }
    $volume = @($partition | Get-Volume -ErrorAction Stop)[0]
    if ([string]$volume.FileSystemType -ne 'NTFS') { throw 'WIM recovery requires an NTFS destination.' }
    if (Test-Path -LiteralPath ($image + '.partly.json')) {
        $manifest = Get-Content -LiteralPath ($image + '.partly.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($index -eq [int]$manifest.index -and $manifest.usedBytes -and [long]$volume.SizeRemaining -lt [long]$manifest.usedBytes) { throw 'The destination has insufficient space for the backed-up files.' }
    }
    Write-ProgressEvent 'Checking WIM image integrity...' 2
    Invoke-Native (Get-ToolPath 'dism.exe') @('/English', '/Get-WimInfo', ('/WimFile:' + $image), ('/Index:' + $index)) | Out-Null
    $partition = Get-TargetPartition $Request.target
    Assert-NotCancelled
    $script:StartedWriting = $true
    Write-ProgressEvent 'Restoring the verified image to the selected data volume...' 8 $false
    $text = Invoke-Native (Get-ToolPath 'dism.exe') @('/English', '/Apply-Image', ('/ImageFile:' + $image), ('/Index:' + $index), ('/ApplyDir:' + $root), '/CheckIntegrity', '/Verify', '/EA') $false
    Write-ProgressEvent 'Recovery completed.' 100 $false
    return @{ success = $true; message = 'Backup files were restored to the empty destination volume.'; output = $text; destinationDrive = $letter }
}
function Restore-WindowsBackup($Request) {
    Assert-Administrator
    $capabilities = Get-Capabilities
    if (-not $capabilities.supportsWbadminRecovery) { throw 'This Windows edition cannot run wbadmin volume recovery online. Boot Windows Recovery Environment and choose System Image Recovery, or restore a Partly 20 WIM backup to an empty data volume here.' }
    if ([string]$Request.version -notmatch '^\d{2}/\d{2}/\d{4}-\d{2}:\d{2}$') { throw 'Invalid backup version identifier.' }
    $partition = Get-TargetPartition $Request.target
    $destination = Get-DriveLetter $Request.destinationDrive
    if ([string]$partition.DriveLetter -cne $destination) { throw 'The restore destination drive letter changed.' }
    $source = Get-DriveLetter $Request.sourceDrive
    $location = Get-BackupDestination $Request.backupTarget
    if ($location -eq ($destination + ':')) { throw 'The restore volume cannot contain its own backup.' }
    $machine = if ($Request.machine) { [string]$Request.machine } else { $env:COMPUTERNAME }
    if ($machine -notmatch '^[A-Za-z0-9_.-]{1,63}$') { throw 'Invalid backup computer name.' }
    Assert-NotCancelled; $script:StartedWriting = $true
    Write-ProgressEvent 'Windows is restoring the selected volume...' 0 $false
    $text = Invoke-Native $capabilities.wbadmin @('start', 'recovery', ('-version:' + [string]$Request.version), '-itemType:Volume', ('-items:' + $source + ':'), ('-recoveryTarget:' + $destination + ':'), ('-backupTarget:' + $location), ('-machine:' + $machine), '-quiet') $false
    return @{ success = $true; message = 'Windows volume recovery completed.'; output = $text }
}
function Assert-MicrosoftExecutable($Path) {
    $signature = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    if ([string]$signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'The executable must have a valid Microsoft Authenticode signature.' }
}
function Install-Disk2vhd($Request) {
    if ($Request.acceptDownload -ne $true) { throw 'Confirm downloading Disk2vhd from Microsoft before continuing.' }
    $destination = if ($Request.destination) { Get-AbsolutePath $Request.destination } else { Join-Path $env:LOCALAPPDATA 'Partly20\Tools\Disk2vhd' }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('partly20-disk2vhd-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        Assert-NotCancelled
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $temporary 'Disk2vhd.zip'
        Write-ProgressEvent 'Downloading Disk2vhd from Microsoft Sysinternals...' 5
        Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/Disk2vhd.zip' -OutFile $zip -UseBasicParsing -ErrorAction Stop
        Assert-NotCancelled
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $temporary 'files') -ErrorAction Stop
        $source = Join-Path $temporary 'files\disk2vhd64.exe'
        if (-not (Test-Path -LiteralPath $source)) { throw 'The Microsoft download did not contain disk2vhd64.exe.' }
        Assert-MicrosoftExecutable $source
        if (-not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination | Out-Null }
        Copy-Item -LiteralPath $source -Destination (Join-Path $destination 'disk2vhd64.exe') -Force
        $license = Join-Path $temporary 'files\Eula.txt'
        $licenseText = if (Test-Path -LiteralPath $license) { Get-Content -LiteralPath $license -Raw } else { '' }
        if ($licenseText) { $licenseText | Set-Content -LiteralPath (Join-Path $destination 'Eula.txt') -Encoding UTF8 }
        return @{ success = $true; toolPath = (Join-Path $destination 'disk2vhd64.exe'); eula = $licenseText; eulaAccepted = $false; licenseUrl = 'https://learn.microsoft.com/en-us/sysinternals/license-terms'; message = 'Microsoft Disk2vhd was downloaded and its signature verified. Its license has not been accepted.' }
    } finally {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporary)
        $expectedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolvedTemporary.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTemporary).StartsWith('partly20-disk2vhd-')) { Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
function Convert-VirtualDisk($Request) {
    Assert-Administrator
    $inputFile = Get-AbsolutePath $Request.inputPath
    if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw 'The source virtual disk file does not exist.' }
    $destination = Assert-NewOutput $Request.destinationPath '^\.(vhd|vhdx|vmdk|vdi|qcow2)$'
    if ($inputFile -eq $destination) { throw 'Source and destination virtual disk files must differ.' }
    $format = [IO.Path]::GetExtension($destination).TrimStart('.').ToLowerInvariant()
    if ($Request.format -and [string]$Request.format -ne $format) { throw 'The destination extension must match the selected virtual disk format.' }
    $allocation = if ($Request.allocation) { [string]$Request.allocation } else { 'Dynamic' }
    if ($allocation -notin @('Dynamic', 'Fixed')) { throw 'Choose Dynamic or Fixed allocation.' }
    $capabilities = Get-Capabilities
    Assert-NotCancelled; $script:Artifacts.Add($destination)
    Write-ProgressEvent 'Converting the existing virtual disk into a new image...' 0
    if ($capabilities.nativeVhd -and $format -in @('vhd', 'vhdx') -and [IO.Path]::GetExtension($inputFile) -in @('.vhd', '.vhdx')) {
        if (-not ('Partly20VirtualDisk' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
public static class Partly20VirtualDisk {
    [StructLayout(LayoutKind.Sequential)] public struct StorageType { public uint DeviceId; public Guid VendorId; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct ParametersV2 {
        public Guid UniqueId; public ulong MaximumSize; public uint BlockSize; public uint SectorSize; public uint PhysicalSectorSize;
        [MarshalAs(UnmanagedType.LPWStr)] public string ParentPath;
        [MarshalAs(UnmanagedType.LPWStr)] public string SourcePath;
        public uint OpenFlags; public StorageType ParentType; public StorageType SourceType; public Guid ResiliencyGuid;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Parameters { public uint Version; public ParametersV2 V2; }
    [DllImport("virtdisk.dll",CharSet=CharSet.Unicode)] static extern uint CreateVirtualDisk(ref StorageType type,string path,uint access,IntPtr security,uint flags,uint provider,ref Parameters parameters,IntPtr overlapped,out IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    static readonly Guid MicrosoftVendor = new Guid("ec984aec-a0f9-47e9-901f-71415a66345b");
    static void Convert(string source,string destination,bool fixedAllocation) {
        if (File.Exists(destination)) throw new IOException("The destination already exists.");
        if (Marshal.OffsetOf(typeof(Parameters),"V2").ToInt32()!=8 || Marshal.SizeOf(typeof(Parameters))!=128) throw new PlatformNotSupportedException("Unexpected Windows virtual disk ABI.");
        StorageType output = new StorageType { DeviceId=Path.GetExtension(destination).Equals(".vhdx",StringComparison.OrdinalIgnoreCase)?3U:2U, VendorId=MicrosoftVendor };
        StorageType input = new StorageType { DeviceId=Path.GetExtension(source).Equals(".vhdx",StringComparison.OrdinalIgnoreCase)?3U:2U, VendorId=MicrosoftVendor };
        Parameters parameters = new Parameters { Version=2, V2=new ParametersV2 { UniqueId=Guid.NewGuid(), SourcePath=source, SourceType=input, SectorSize=512 } };
        IntPtr handle;
        using (var readLock=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read)) {
            uint result=CreateVirtualDisk(ref output,destination,0,IntPtr.Zero,fixedAllocation?1U:0U,0,ref parameters,IntPtr.Zero,out handle);
            if(result!=0) throw new Win32Exception((int)result,"Windows virtual disk conversion failed.");
            if(handle!=IntPtr.Zero && handle!=new IntPtr(-1)) CloseHandle(handle);
        }
    }
    public static Task ConvertAsync(string source,string destination,bool fixedAllocation) { return Task.Run(()=>Convert(source,destination,fixedAllocation)); }
}
'@
        }
        Write-ProgressEvent 'Windows is converting the virtual disk. Cancellation is deferred until the provider finishes.' 5 $false
        $conversion = [Partly20VirtualDisk]::ConvertAsync($inputFile, $destination, ($allocation -eq 'Fixed'))
        while (-not $conversion.IsCompleted) { [Threading.Thread]::Sleep(500); if (([DateTime]::UtcNow.Second % 4) -eq 0) { Write-ProgressEvent 'Windows is copying virtual disk blocks into the new image...' -1 $false } }
        if ($conversion.IsFaulted) { throw $conversion.Exception.InnerException }
        $backend = 'Windows Virtual Disk API'
    } elseif ($capabilities.convertVhd -and $format -in @('vhd', 'vhdx') -and [IO.Path]::GetExtension($inputFile) -in @('.vhd', '.vhdx')) {
        Write-ProgressEvent 'Hyper-V is converting the virtual disk. Cancellation is deferred until the provider finishes.' 5 $false
        Convert-VHD -Path $inputFile -DestinationPath $destination -VHDType $allocation -ErrorAction Stop
        $backend = 'Microsoft Hyper-V Convert-VHD'
    } elseif ($capabilities.qemuImg) {
        $qemuFormat = @{ vhd = 'vpc'; vhdx = 'vhdx'; vmdk = 'vmdk'; vdi = 'vdi'; qcow2 = 'qcow2' }[$format]
        $args = @('convert', '-p', '-O', $qemuFormat)
        if ($allocation -eq 'Fixed') {
            $option = @{ vhd = 'subformat=fixed'; vhdx = 'subformat=fixed'; vmdk = 'subformat=monolithicFlat'; vdi = 'static=on'; qcow2 = 'preallocation=full' }[$format]
            $args += @('-o', $option)
        }
        $args += @($inputFile, $destination)
        Invoke-Native $capabilities.qemuImg $args $true | Out-Null
        Invoke-Native $capabilities.qemuImg @('info', '--output=json', $destination) $false | Out-Null
        $backend = 'QEMU qemu-img'
    } else { throw 'Install the Hyper-V PowerShell management tools for VHD/VHDX conversion, or install QEMU with qemu-img for VMDK, VDI, and QCOW2 conversion. Refresh tool availability afterward.' }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw 'The conversion tool did not produce the requested virtual disk.' }
    Write-ProgressEvent 'Virtual disk conversion completed.' 100 $false
    return @{ success = $true; message = 'Virtual-to-virtual disk migration completed.'; destinationPath = $destination; backend = $backend; size = (Get-Item -LiteralPath $destination).Length }
}
function Export-PhysicalDisk($Request) {
    Assert-Administrator
    if ($Request.acceptEula -ne $true) { throw 'Read and accept the Microsoft Sysinternals license before running Disk2vhd.' }
    $destination = Assert-NewOutput $Request.destinationPath '^\.vhdx?$'
    $tool = if ($Request.toolPath) { Get-AbsolutePath $Request.toolPath } else { Get-Disk2vhdPath }
    if (-not $tool) { throw 'Download Disk2vhd from Microsoft using the tool download action first.' }
    Assert-MicrosoftExecutable $tool
    $letters = @($Request.sourceDrives | ForEach-Object { Get-DriveLetter $_ } | Select-Object -Unique)
    if ($letters.Count -lt 1) { throw 'Choose at least one physical source volume.' }
    foreach ($letter in $letters) { Assert-Decrypted (Get-Volume -DriveLetter $letter -ErrorAction Stop) }
    $captureDestination = if ([IO.Path]::GetExtension($destination) -eq '.vhdx') { Join-Path ([IO.Path]::GetDirectoryName($destination)) ('partly20-capture-' + [guid]::NewGuid().ToString('N') + '.vhd') } else { $destination }
    Assert-NotCancelled; $script:Artifacts.Add($captureDestination)
    Write-ProgressEvent 'Microsoft Disk2vhd is creating a consistent physical-to-virtual snapshot...' 0 $false
    $arguments = @('-accepteula') + @($letters | ForEach-Object { $_ + ':' }) + @($captureDestination)
    $text = Invoke-Native $tool $arguments $false
    if (-not (Test-Path -LiteralPath $captureDestination -PathType Leaf)) { throw 'Disk2vhd did not create the requested VHD. Check the selected volumes and output location.' }
    if ($captureDestination -ne $destination) {
        Convert-VirtualDisk @{ inputPath = $captureDestination; destinationPath = $destination; format = 'vhdx'; allocation = 'Dynamic' } | Out-Null
        # Only the generated intermediate file is removed; the user-selected output and source disks are preserved.
        if ([IO.Path]::GetFileName($captureDestination).StartsWith('partly20-capture-') -and [IO.Path]::GetDirectoryName($captureDestination) -eq [IO.Path]::GetDirectoryName($destination)) { Remove-Item -LiteralPath $captureDestination -Force }
    }
    return @{ success = $true; message = 'The physical-to-virtual snapshot was created.'; destinationPath = $destination; output = $text }
}
function Invoke-AdkCommand($Adk, [string]$Command, [string[]]$Arguments) {
    # cmd is required by Microsoft's ADK batch tools. Restrict all batch arguments to prevent expansion.
    $values = @([string]$Adk.environment, $Command) + $Arguments
    foreach ($value in $values) { if ($value -match '[&|<>^%!"\r\n]') { throw 'ADK media paths cannot contain command expansion characters. Choose a simple local destination path.' } }
    $line = 'call "' + [string]$Adk.environment + '" && call "' + $Command + '" ' + (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    # cmd.exe parses its own command line. CRT backslash-quote escaping is not
    # valid here; /S removes exactly the outer quotes while retaining each path.
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'System32\cmd.exe'
    $info.Arguments='/d /v:off /s /c "'+$line+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    if(-not $process.Start()){throw 'Windows could not start the ADK media tool.'}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    while(-not $process.WaitForExit(1000)){Write-ProgressEvent 'Windows ADK is preparing recovery media...' -1 $false}
    $text=$stdout.Result+"`n"+$stderr.Result;$code=$process.ExitCode;$process.Dispose()
    if($code -ne 0){throw ('Windows ADK failed (exit '+$code+'). '+$text.Trim())}
    return $text.Trim()
}
function New-RecoveryMedia($Request) {
    Assert-Administrator
    if ([string]$Request.kind -eq 'native') {
        $native = Get-ToolPath 'RecoveryDrive.exe'
        if (-not $native) { throw 'The Windows Recovery Drive wizard is not installed. Install Windows ADK and the WinPE add-on to create ISO/USB media.' }
        # This wizard has its own drive selection and destructive confirmation. No automatic formatting is performed here.
        Start-Process -FilePath $native -WindowStyle Normal -ErrorAction Stop | Out-Null
        return @{ success = $true; launched = $true; message = 'The Windows Recovery Drive wizard is open. Complete its drive selection and confirmation steps to create bootable recovery media.' }
    }
    $adk = Find-Adk
    if (-not $adk.available) { throw 'Install the Windows ADK Deployment Tools and Windows PE add-on first, then refresh tool availability. The Windows Recovery Drive wizard can create a recovery USB without ADK.' }
    $architecture = if ($Request.architecture) { [string]$Request.architecture } else { 'amd64' }
    if ($architecture -notin @('amd64', 'arm64')) { throw 'Choose amd64 or arm64 architecture.' }
    if ([string]$Request.kind -eq 'iso') { $destination = Assert-NewOutput $Request.destination '^\.iso$' }
    elseif ([string]$Request.kind -eq 'usb') {
        $letter = Get-DriveLetter $Request.destination
        if (-not $Request.target.partitionNumber) {
            $selectedPartition = @(Get-Partition -DriveLetter $letter -ErrorAction Stop)[0]
            if ([int]$selectedPartition.DiskNumber -ne [int]$Request.target.diskNumber) { throw 'The selected USB drive letter now belongs to a different disk.' }
            $Request.target | Add-Member -MemberType NoteProperty -Name partitionNumber -Value ([int]$selectedPartition.PartitionNumber) -Force
            $Request.target | Add-Member -MemberType NoteProperty -Name partitionOffset -Value ([long]$selectedPartition.Offset) -Force
        }
        $partition = Get-TargetPartition $Request.target
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        if ([string]$disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem -or [string]$partition.DriveLetter -cne $letter) { throw 'Select the reviewed non-system USB data volume.' }
        $destination = $letter + ':'
    } else { throw 'Choose ISO or USB media.' }
    $workRoot = Join-Path $env:LOCALAPPDATA 'Partly20\Recovery'
    if (-not (Test-Path -LiteralPath $workRoot)) { New-Item -ItemType Directory -Path $workRoot | Out-Null }
    $work = Join-Path $workRoot ([guid]::NewGuid().ToString('N'))
    $script:Artifacts.Add($work)
    Assert-NotCancelled
    Write-ProgressEvent 'Copying the Windows PE boot files...' 5 $false
    Invoke-AdkCommand $adk $adk.copype @($architecture, $work) | Out-Null
    Assert-NotCancelled
    if ([string]$Request.kind -eq 'usb') { Get-TargetPartition $Request.target | Out-Null; $script:StartedWriting = $true }
    $args = @($(if ([string]$Request.kind -eq 'iso') { '/ISO' } else { '/UFD' }), '/F', $work, $destination)
    if ($Request.bootex -eq $true) { $args += '/bootex' }
    Write-ProgressEvent 'Creating bootable Windows PE media...' 40 $false
    $output = Invoke-AdkCommand $adk $adk.makeWinPEMedia $args
    Write-ProgressEvent 'Bootable Windows PE media completed.' 100 $false
    return @{ success = $true; message = 'Bootable Windows PE recovery media was created.'; destination = $destination; workingDirectory = $work; output = $output }
}
function Get-EmptyDestinationDisk($Request) {
    $target = $Request.destinationDisk
    $disk = Get-Disk -Number ([int]$target.diskNumber) -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$target.diskUniqueId) -or [string]$disk.UniqueId -cne [string]$target.diskUniqueId) { throw 'Destination disk identity changed. Refresh and review the copy.' }
    $expected = @($Request.expectedSnapshot.disks | Where-Object { [int]$_.number -eq [int]$disk.Number })
    if ($expected.Count -ne 1 -or [string]$expected[0].uniqueId -cne [string]$disk.UniqueId -or [long]$expected[0].size -ne [long]$disk.Size -or @($expected[0].partitions).Count -gt 0) { throw 'The original snapshot must show an entirely empty destination disk.' }
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly -or $disk.IsOffline -or [string]$disk.HealthStatus -ne 'Healthy' -or [string]$disk.BusType -eq 'Spaces' -or $disk.IsClustered -or [string]$disk.PartitionStyle -notin @('RAW', 'GPT')) { throw 'Choose an empty, healthy, writable, non-system GPT or RAW disk.' }
    if ([string]$disk.PartitionStyle -ne 'RAW' -and @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop).Count -gt 0) { throw 'The destination disk contains partitions. Nothing will be erased automatically.' }
    if ([int]$disk.NumberOfPartitions -gt 0) { throw 'The destination disk must have no partitions.' }
    return $disk
}
function Copy-OperatingSystem($Request) {
    Assert-Administrator; Assert-NotCancelled
    $sourceLetter = Get-DriveLetter $Request.sourceDrive
    $systems = Find-OperatingSystems
    $system = @($systems.systems | Where-Object { $_.sourceDrive -eq $sourceLetter })
    if ($system.Count -ne 1) { throw 'Choose a detected Windows installation.' }
    $disk = Get-EmptyDestinationDisk $Request
    if ([int]$disk.Number -eq [int]$system[0].diskNumber) { throw 'The Windows source and destination disk must differ.' }
    $staging = Get-AbsolutePath $Request.stagingDirectory
    if (-not (Test-Path -LiteralPath $staging -PathType Container)) { throw 'Choose an existing local or network image staging folder.' }
    if ($staging -match '^[A-Za-z]:\\') {
        $stagingLetter = [IO.Path]::GetPathRoot($staging).Substring(0, 1)
        $stagingPartition = @(Get-Partition -DriveLetter $stagingLetter -ErrorAction Stop)[0]
        if ([int]$stagingPartition.DiskNumber -eq [int]$disk.Number -or $stagingLetter -eq $sourceLetter) { throw 'The staging folder must be outside the Windows source volume and the destination disk. A network share is also supported.' }
    } elseif ($staging -notmatch '^\\\\[^\\]+\\[^\\]+') { throw 'Choose a drive folder or network share for image staging.' }
    $required = [long]$system[0].size - [long]$system[0].sizeRemaining + 1073741824
    if ([long]$disk.Size -lt $required + 350 * 1048576) { throw 'The empty destination disk is too small for the Windows installation.' }
    $freeLetters = @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z' | Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) })
    if ($freeLetters.Count -lt 2) { throw 'Two available drive letters are required while preparing the copied Windows installation.' }
    $image = Join-Path $staging ('Partly20-Windows-' + [guid]::NewGuid().ToString('N') + '.wim')
    $script:RecoveryDetails = @{ imagePath = $image; destinationDisk = [int]$disk.Number }
    New-WimBackup $sourceLetter $image | Out-Null
    Assert-NotCancelled
    $disk = Get-EmptyDestinationDisk $Request
    $script:StartedWriting = $true
    Write-ProgressEvent 'Preparing EFI, reserved, and Windows partitions on the empty destination...' 50 $false
    if ([string]$disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null }
    $efi = New-Partition -DiskNumber $disk.Number -Size (300 * 1048576) -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -DriveLetter ([char]$freeLetters[0]) -ErrorAction Stop
    $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'SYSTEM' -Confirm:$false -ErrorAction Stop | Out-Null
    New-Partition -DiskNumber $disk.Number -Size (16 * 1048576) -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -ErrorAction Stop | Out-Null
    $windowsPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter ([char]$freeLetters[1]) -ErrorAction Stop
    $windowsPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false -ErrorAction Stop | Out-Null
    $destinationRoot = $freeLetters[1] + ':\'; $efiRoot = $freeLetters[0] + ':'
    Write-ProgressEvent 'Applying the Windows snapshot to the new disk...' 60 $false
    Invoke-Native (Get-ToolPath 'dism.exe') @('/English', '/Apply-Image', ('/ImageFile:' + $image), '/Index:1', ('/ApplyDir:' + $destinationRoot), '/CheckIntegrity', '/Verify', '/EA') $false | Out-Null
    Write-ProgressEvent 'Writing UEFI boot files for the copied Windows installation...' 92 $false
    Invoke-Native (Get-ToolPath 'bcdboot.exe') @((Join-Path $destinationRoot 'Windows'), '/s', $efiRoot, '/f', 'UEFI') $false | Out-Null
    $efi | Remove-PartitionAccessPath -AccessPath ($efiRoot + '\') -ErrorAction Stop | Out-Null
    Write-ProgressEvent 'Windows copy completed. The recovery image was retained.' 100 $false
    return @{ success = $true; message = 'Windows was copied to the empty disk and UEFI boot files were created. Choose that disk in firmware to boot the copied installation.'; destinationDiskNumber = [int]$disk.Number; windowsDrive = $freeLetters[1]; recoveryImage = $image; imageRetained = $true }
}

try {
    Import-Module Storage -ErrorAction Stop
    $request = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    switch ($Action) {
        'capabilities' { $result = Get-Capabilities }
        'findOperatingSystems' { $result = Find-OperatingSystems }
        'backup' { if ([string]$request.mode -eq 'wim') { $result = New-WimBackup $request.sourceDrive $request.imagePath } else { $result = Invoke-WindowsBackup $request } }
        'listBackups' { $result = Get-Backups $request }
        'restore' { if ($request.imagePath) { $result = Restore-Wim $request } else { $result = Restore-WindowsBackup $request } }
        'migrate' { if ($request.inputPath) { $result = Convert-VirtualDisk $request } else { $result = Export-PhysicalDisk $request } }
        'downloadDisk2vhd' { $result = Install-Disk2vhd $request }
        'recoveryMedia' { $result = New-RecoveryMedia $request }
        'copyOperatingSystem' { $result = Copy-OperatingSystem $request }
    }
    $result | ConvertTo-Json -Depth 12 -Compress | Write-Output
    exit 0
} catch {
    $cancelled = $_.Exception -is [OperationCanceledException]
    @{ success = $false; cancelled = $cancelled; error = $(if ($cancelled) { $null } else { @{ code = 'SYSTEM_TOOL_ERROR'; message = $_.Exception.Message } }); message = $_.Exception.Message; diskWritesStarted = $script:StartedWriting; artifacts = @($script:Artifacts.ToArray()); recovery = $script:RecoveryDetails } | ConvertTo-Json -Depth 8 -Compress | Write-Output
    exit $(if ($cancelled) { 0 } else { 1 })
}
