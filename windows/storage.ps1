param(
    [Parameter(Mandatory = $true)][ValidateSet('inventory', 'limits', 'apply', 'check')][string]$Action,
    [Parameter(Mandatory = $true)][string]$PayloadPath
)

# Windows PowerShell 5.1 compatible. The only executable inputs are a fixed action and JSON data.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:Applied = New-Object 'System.Collections.Generic.List[object]'
$script:CurrentOperation = $null

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Letter($Value) {
    $letter = [string]$Value
    if ($letter -eq [string][char]0) { return '' }
    return $letter.Trim().ToUpperInvariant()
}

function Get-VolumeForPartition($Partition) {
    try { return @($Partition | Get-Volume -ErrorAction Stop)[0] } catch { return $null }
}

function Get-EncryptionState($Partition, $Volume) {
    # The encryption provider requires elevation. Avoid repeatedly asking it during a standard-user inventory.
    if ($Action -eq 'inventory' -and -not (Test-Administrator)) { return 'Unknown' }
    try {
        $items = @(Get-CimInstance -Namespace 'Root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop)
        $volumePath = [string]$Volume.Path
        $partitionPaths = @($Partition.AccessPaths | ForEach-Object { ([string]$_).TrimEnd('\') })
        $letter = Get-Letter $Partition.DriveLetter
        $encrypted = @($items | Where-Object { ($volumePath -and ([string]$_.DeviceID).TrimEnd('\') -eq $volumePath.TrimEnd('\')) -or $partitionPaths -contains ([string]$_.DeviceID).TrimEnd('\') -or ($letter -and [string]$_.DriveLetter -eq ($letter + ':')) })
        if ($encrypted.Count -eq 0) { return 'Unencrypted' }
        $lock = Invoke-CimMethod -InputObject $encrypted[0] -MethodName GetLockStatus -ErrorAction Stop
        if ($lock.ReturnValue -ne 0) { return 'Unknown' }
        if ($lock.LockStatus -ne 0) { return 'Locked' }
        $conversion = Invoke-CimMethod -InputObject $encrypted[0] -MethodName GetConversionStatus -ErrorAction Stop
        if ($conversion.ReturnValue -ne 0) { return 'Unknown' }
        if ($conversion.ConversionStatus -ne 0) { return 'Encrypted' }
        return 'Unencrypted'
    } catch {
        try {
            if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { return 'Unknown' }
            $mount = [string]$Volume.Path
            $bitlocker = Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop
            if ([string]$bitlocker.LockStatus -eq 'Locked') { return 'Locked' }
            if ([string]$bitlocker.VolumeStatus -ne 'FullyDecrypted') { return 'Encrypted' }
            return 'Unencrypted'
        } catch { return 'Unknown' }
    }
}

function Get-ProtectionReason($Partition, $Volume, $EncryptionState) {
    if ($Partition.IsBoot -or $Partition.IsSystem) { return 'Windows boot or system partition' }
    $letter = Get-Letter $Partition.DriveLetter
    if ($letter -and ($letter + ':') -eq $env:SystemDrive) { return 'Running Windows partition' }
    $gpt = ([string]$Partition.GptType).Trim('{}').ToLowerInvariant()
    if ($gpt -and $gpt -ne 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7') { return 'Reserved, recovery, or non-data GPT partition' }
    if ([string]$Partition.Type -match 'System|Reserved|Recovery|Extended|Unknown') { return 'Reserved, recovery, or unsupported partition type' }
    if ($Partition.IsReadOnly) { return 'Read-only partition' }
    if ($EncryptionState -eq 'Locked') { return 'BitLocker volume is locked' }
    if ($EncryptionState -eq 'Encrypted') { return 'BitLocker encrypted volume; decrypt it in Windows first' }
    return ''
}

function Get-DiskPartitions($Disk) {
    if ([string]$Disk.PartitionStyle -eq 'RAW') { return @() }
    return @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop | Sort-Object Offset)
}

function Get-Inventory {
    $disks = @(foreach ($disk in @(Get-Disk -ErrorAction Stop | Sort-Object Number)) {
        $partitions = @(foreach ($partition in @(Get-DiskPartitions $disk)) {
            $volume = Get-VolumeForPartition $partition
            $encryption = Get-EncryptionState $partition $volume
            $reason = Get-ProtectionReason $partition $volume $encryption
            [ordered]@{
                diskNumber = [int]$partition.DiskNumber; partitionNumber = [int]$partition.PartitionNumber
                offset = [long]$partition.Offset; size = [long]$partition.Size; driveLetter = Get-Letter $partition.DriveLetter
                label = [string]$volume.FileSystemLabel; fileSystem = [string]$volume.FileSystemType
                sizeRemaining = $(if ($volume) { [long]$volume.SizeRemaining } else { $null })
                isBoot = [bool]$partition.IsBoot; isSystem = [bool]$partition.IsSystem; isHidden = [bool]$partition.IsHidden
                isReadOnly = [bool]$partition.IsReadOnly; gptType = [string]$partition.GptType; type = [string]$partition.Type
                isProtected = [bool]$reason; protectionReason = $reason; encryptionState = $encryption
            }
        })
        [ordered]@{
            number = [int]$disk.Number; friendlyName = [string]$disk.FriendlyName; serialNumber = ([string]$disk.SerialNumber).Trim()
            uniqueId = [string]$disk.UniqueId; size = [long]$disk.Size; partitionStyle = [string]$disk.PartitionStyle
            busType = [string]$disk.BusType; isBoot = [bool]$disk.IsBoot; isSystem = [bool]$disk.IsSystem
            logicalSectorSize = [int]$disk.LogicalSectorSize; physicalSectorSize = [int]$disk.PhysicalSectorSize
            isOffline = [bool]$disk.IsOffline; isReadOnly = [bool]$disk.IsReadOnly
            operationalStatus = (@($disk.OperationalStatus) -join ', '); healthStatus = [string]$disk.HealthStatus
            partitions = $partitions
        }
    })
    return [ordered]@{ disks = $disks; isAdmin = Test-Administrator; scannedAt = [DateTime]::UtcNow.ToString('o') }
}

function Assert-Integer($Value, $Name, [long]$Minimum = 0) {
    if ($null -eq $Value -or [string]$Value -notmatch '^\d+$') { throw "$Name must be a non-negative whole number." }
    $number = [long]$Value
    if ($number -lt $Minimum -or $number -gt 9007199254740991) { throw "$Name is outside the supported range." }
    return $number
}

function Get-TargetDisk($Target, [bool]$Writable = $false) {
    $number = Assert-Integer $Target.diskNumber 'Disk number'
    if ([string]::IsNullOrWhiteSpace([string]$Target.diskUniqueId)) { throw 'Disk identity is missing. Refresh the disk list.' }
    $disk = Get-Disk -Number $number -ErrorAction Stop
    if ([string]$disk.UniqueId -cne [string]$Target.diskUniqueId) { throw 'Disk identity changed. Refresh the disk list before continuing.' }
    if ($Writable) {
        if ($disk.IsOffline) { throw 'The target disk is offline. Bring it online using Windows Disk Management first.' }
        if ($disk.IsReadOnly) { throw 'The target disk is read-only.' }
        if ([string]$disk.HealthStatus -ne 'Healthy') { throw 'The target disk does not report healthy status.' }
        if ([string]$disk.BusType -eq 'Spaces') { throw 'Storage Spaces disks must be managed using Windows Storage Spaces.' }
        if ($disk.IsClustered) { throw 'Clustered disks must be managed using the cluster administration tools.' }
    }
    return $disk
}

function Get-TargetPartition($Target, [bool]$Writable = $false) {
    $disk = Get-TargetDisk $Target $Writable
    $number = Assert-Integer $Target.partitionNumber 'Partition number' 1
    $offset = Assert-Integer $Target.partitionOffset 'Partition offset'
    $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $number -ErrorAction Stop
    if ([long]$partition.Offset -ne $offset) { throw 'Partition location changed. Refresh the disk list before continuing.' }
    if ($Writable) {
        $volume = Get-VolumeForPartition $partition
        $encryption = Get-EncryptionState $partition $volume
        $reason = Get-ProtectionReason $partition $volume $encryption
        if ($reason) { throw "This partition is protected: $reason." }
        # Existing volumes must have a readable encryption state before any change.
        if ($encryption -eq 'Unknown') { throw 'Windows could not verify the volume encryption status. No change was made.' }
    }
    return $partition
}

function Assert-Snapshot($Request) {
    if ($null -eq $Request.expectedSnapshot -or $null -eq $Request.expectedSnapshot.disks) { throw 'The original disk snapshot is required.' }
    $targetNumbers = @($Request.operations | ForEach-Object { [int]$_.diskNumber } | Sort-Object -Unique)
    foreach ($number in $targetNumbers) {
        $expected = @($Request.expectedSnapshot.disks | Where-Object { [int]$_.number -eq $number })
        if ($expected.Count -ne 1) { throw "Disk $number is missing from the original snapshot." }
        $before = $expected[0]
        $actual = Get-Disk -Number $number -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$before.uniqueId) -or [string]$actual.UniqueId -cne [string]$before.uniqueId -or [long]$actual.Size -ne [long]$before.size -or [string]$actual.PartitionStyle -ne [string]$before.partitionStyle -or ([string]$actual.SerialNumber).Trim() -cne ([string]$before.serialNumber).Trim()) { throw "Disk $number changed since the queue was prepared. Refresh and review the operations." }
        $partitions = @(Get-DiskPartitions $actual)
        $expectedPartitions = @($before.partitions)
        if ($partitions.Count -ne $expectedPartitions.Count) { throw "Partitions on disk $number changed. Refresh and review the operations." }
        foreach ($partition in $partitions) {
            $previous = @($expectedPartitions | Where-Object { [int]$_.partitionNumber -eq [int]$partition.PartitionNumber })
            if ($previous.Count -ne 1 -or [long]$previous[0].offset -ne [long]$partition.Offset -or [long]$previous[0].size -ne [long]$partition.Size -or (Get-Letter $previous[0].driveLetter) -cne (Get-Letter $partition.DriveLetter)) { throw "Partition geometry or drive letters on disk $number changed. Refresh and review the operations." }
        }
    }
}

function Assert-FileSystemAndLabel($Parameters, [long]$Size = 0) {
    if ([string]$Parameters.fileSystem -cnotin @('NTFS', 'exFAT', 'FAT32')) { throw 'Unsupported file system. Choose NTFS, exFAT, or FAT32.' }
    Assert-Label $Parameters.label
    if ([string]$Parameters.fileSystem -eq 'FAT32' -and ([string]$Parameters.label).Length -gt 11) { throw 'FAT32 volume labels have a maximum of 11 characters.' }
    if ([string]$Parameters.fileSystem -eq 'exFAT' -and ([string]$Parameters.label).Length -gt 15) { throw 'exFAT volume labels have a maximum of 15 characters.' }
    if ([string]$Parameters.fileSystem -eq 'FAT32' -and $Size -gt 34359738368) { throw 'Windows FAT32 formatting is limited to 32 GiB. Choose NTFS or exFAT.' }
    if ($Parameters.allocationUnitSize -and [long]$Parameters.allocationUnitSize -notin @(512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432)) { throw 'Unsupported allocation unit size.' }
    if ($Parameters.enableCompression -and ([string]$Parameters.fileSystem -ne 'NTFS' -or [long]$Parameters.allocationUnitSize -gt 4096)) { throw 'Compression requires NTFS with allocation units no larger than 4096 bytes.' }
}

function Invoke-VolumeFormat($Partition, $Parameters) {
    $format = @{ Partition = $Partition; FileSystem = [string]$Parameters.fileSystem; NewFileSystemLabel = [string]$Parameters.label; Confirm = $false; ErrorAction = 'Stop' }
    if ($Parameters.allocationUnitSize) { $format.AllocationUnitSize = [uint32]$Parameters.allocationUnitSize }
    if ($Parameters.fullFormat) { $format.Full = $true }
    if ($Parameters.enableCompression) { $format.Compress = $true }
    Format-Volume @format | Out-Null
}

function Assert-Label($Label) {
    if (([string]$Label).Length -gt 32 -or [string]$Label -match '[\\/:*?"<>|\x00-\x1f]') { throw 'The volume label contains unsupported characters or is too long.' }
}

function Assert-Letter($Letter, $TargetPartition) {
    if ([string]$Letter -cnotmatch '^[A-Z]?$') { throw 'Choose a drive letter from A to Z, or no drive letter.' }
    if (-not [string]$Letter) { return }
    $used = @(Get-Partition -ErrorAction Stop | Where-Object { (Get-Letter $_.DriveLetter) -eq [string]$Letter })
    if (@($used | Where-Object { $null -eq $TargetPartition -or $_.DiskNumber -ne $TargetPartition.DiskNumber -or $_.PartitionNumber -ne $TargetPartition.PartitionNumber }).Count -gt 0) { throw "Drive letter $Letter is already in use." }
    $drive = Get-PSDrive -Name $Letter -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($drive -and $used.Count -eq 0) { throw "Drive letter $Letter is already mapped." }
}

function Assert-CreateGap($Operation, $Disk) {
    if ([string]$Disk.PartitionStyle -notin @('GPT', 'MBR')) { throw 'Initialize the empty disk as GPT before creating a partition.' }
    $offset = Assert-Integer $Operation.params.offset 'Partition offset' 1048576
    $size = Assert-Integer $Operation.params.size 'Partition size' 1048576
    if ($offset % 1048576 -ne 0 -or $size % 1048576 -ne 0) { throw 'New partition offset and size must be aligned to 1 MiB.' }
    $end = $offset + $size
    if ($end -le $offset -or $end -gt ([long]$Disk.Size - 1048576)) { throw 'The requested partition exceeds the disk usable area.' }
    foreach ($existing in @(Get-DiskPartitions $Disk)) {
        if ($offset -lt ([long]$existing.Offset + [long]$existing.Size) -and $end -gt [long]$existing.Offset) { throw 'The requested space is no longer unallocated. Refresh and review the queue.' }
    }
    if ([string]$Disk.PartitionStyle -eq 'MBR' -and $end -gt 2199023255552) { throw 'MBR partitions cannot extend past 2 TiB. Use a GPT disk.' }
}

function Assert-Operation($Operation, [bool]$Preflight = $false) {
    if ([string]$Operation.type -cnotin @('create', 'resize', 'format', 'delete', 'letter', 'label', 'hide', 'initialize')) { throw 'Unsupported storage operation.' }
    $disk = Get-TargetDisk $Operation $true
    if ($Operation.type -eq 'initialize') {
        if ([string]$Operation.params.partitionStyle -cne 'GPT' -or [string]$disk.PartitionStyle -ne 'RAW' -or $disk.IsBoot -or $disk.IsSystem -or [int]$disk.NumberOfPartitions -ne 0) { throw 'Only an empty, uninitialized disk can be initialized as GPT.' }
        return
    }
    if ($Operation.type -eq 'create') {
        $size = Assert-Integer $Operation.params.size 'Partition size' 1048576
        $offset = Assert-Integer $Operation.params.offset 'Partition offset' 1048576
        if ($offset % 1048576 -ne 0 -or $size % 1048576 -ne 0) { throw 'New partition offset and size must be aligned to 1 MiB.' }
        Assert-FileSystemAndLabel $Operation.params $size
        if (-not $Preflight) { Assert-Letter $Operation.params.driveLetter $null }
        # A preceding queue operation may free space or initialize this disk; validate immediately before creation.
        if (-not $Preflight) { Assert-CreateGap $Operation $disk }
        return
    }
    $partition = Get-TargetPartition $Operation $true
    switch ($Operation.type) {
        'resize' {
            $size = Assert-Integer $Operation.params.size 'Partition size' 1048576
            if ($size % 1048576 -ne 0) { throw 'Partition size must be aligned to 1 MiB.' }
            $limits = $partition | Get-PartitionSupportedSize -ErrorAction Stop
            if ($size -lt [long]$limits.SizeMin -or (-not $Preflight -and $size -gt [long]$limits.SizeMax)) { throw 'The requested size is outside the current Windows supported limits.' }
        }
        'format' { Assert-FileSystemAndLabel $Operation.params ([long]$partition.Size) }
        'letter' { if (-not $Preflight) { Assert-Letter $Operation.params.driveLetter $partition } }
        'label' {
            Assert-Label $Operation.params.label
            $labelVolume = Get-VolumeForPartition $partition
            if ($null -eq $labelVolume) { throw 'This partition has no accessible file system.' }
            if ([string]$labelVolume.FileSystemType -eq 'FAT32' -and ([string]$Operation.params.label).Length -gt 11) { throw 'FAT32 volume labels have a maximum of 11 characters.' }
            if ([string]$labelVolume.FileSystemType -eq 'exFAT' -and ([string]$Operation.params.label).Length -gt 15) { throw 'exFAT volume labels have a maximum of 15 characters.' }
        }
        'hide' { if ($Operation.params.hidden -isnot [bool]) { throw 'Hidden state must be true or false.' } }
    }
}

function Write-OperationProgress($Operation, $State, $Index, $Total) {
    $event = @{ id = [string]$Operation.id; state = $State; index = $Index; total = $Total; type = [string]$Operation.type }
    [Console]::Error.WriteLine('PARTLY20_PROGRESS:' + ($event | ConvertTo-Json -Compress))
}

function Invoke-StorageOperation($Operation) {
    $disk = Get-TargetDisk $Operation $true
    if ($Operation.type -eq 'initialize') {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false -ErrorAction Stop | Out-Null
        return
    }
    if ($Operation.type -eq 'create') {
        $parameters = @{ DiskNumber = [int]$disk.Number; Offset = [long]$Operation.params.offset; Size = [long]$Operation.params.size; ErrorAction = 'Stop' }
        if ($Operation.params.driveLetter) { $parameters.DriveLetter = [char]$Operation.params.driveLetter }
        $created = New-Partition @parameters
        # A format failure leaves the new partition in place and is reported as a partial operation.
        $script:CurrentOperation.createdPartitionNumber = [int]$created.PartitionNumber
        Invoke-VolumeFormat $created $Operation.params
        return
    }
    $partition = Get-TargetPartition $Operation $true
    switch ($Operation.type) {
        'resize' { $partition | Resize-Partition -Size ([long]$Operation.params.size) -Confirm:$false -ErrorAction Stop | Out-Null }
        'format' { Invoke-VolumeFormat $partition $Operation.params }
        'delete' { $partition | Remove-Partition -Confirm:$false -ErrorAction Stop | Out-Null }
        'letter' {
            if ([string]$Operation.params.driveLetter) {
                $partition | Set-Partition -NewDriveLetter ([char]$Operation.params.driveLetter) -Confirm:$false -ErrorAction Stop | Out-Null
            } else {
                $currentLetter = Get-Letter $partition.DriveLetter
                if ($currentLetter) { $partition | Remove-PartitionAccessPath -AccessPath ($currentLetter + ':\') -Confirm:$false -ErrorAction Stop | Out-Null }
            }
        }
        'label' { $partition | Get-Volume -ErrorAction Stop | Set-Volume -NewFileSystemLabel ([string]$Operation.params.label) -ErrorAction Stop | Out-Null }
        'hide' { $partition | Set-Partition -IsHidden ([bool]$Operation.params.hidden) -Confirm:$false -ErrorAction Stop | Out-Null }
    }
}

try {
    Import-Module Storage -ErrorAction Stop
    $request = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    switch ($Action) {
        'inventory' { $result = Get-Inventory }
        'limits' {
            $partition = Get-TargetPartition $request.target $false
            $limits = $partition | Get-PartitionSupportedSize -ErrorAction Stop
            $result = @{ sizeMin = [long]$limits.SizeMin; sizeMax = [long]$limits.SizeMax }
        }
        'check' {
            if (-not (Test-Administrator)) { throw 'Run Partly 20 as administrator to check a file system.' }
            $partition = Get-TargetPartition $request.target $false
            $volume = Get-VolumeForPartition $partition
            if ($null -eq $volume -or [string]$volume.FileSystemType -notin @('NTFS','FAT','FAT32','exFAT')) { throw 'Choose an accessible NTFS, FAT, FAT32, or exFAT file system.' }
            $encryption = Get-EncryptionState $partition $volume
            if ($encryption -eq 'Locked' -or $encryption -eq 'Unknown') { throw 'Unlock the volume and verify its encryption state before scanning.' }
            if ([string]$volume.FileSystemType -eq 'NTFS') {
                $scan = [string]($volume | Repair-Volume -Scan -ErrorAction Stop)
            } else {
                $letter = Get-Letter $partition.DriveLetter
                if (-not $letter) { throw 'Assign a drive letter before checking this file system.' }
                $scanOutput = & "$env:SystemRoot\System32\chkdsk.exe" ($letter + ':') 2>&1
                $scanCode = $LASTEXITCODE
                if ($scanCode -gt 1) { throw ('Windows could not finish checking the file system. ' + ($scanOutput -join "`n")) }
                $scan = $scanOutput -join "`n"
            }
            $cancelled = $request.cancelPath -and (Test-Path -LiteralPath $request.cancelPath)
            $result = @{ success = $true; cancelled = [bool]$cancelled; result = $scan; message = $scan; checkedAt = [DateTime]::UtcNow.ToString('o'); repairsAttempted = $false }
        }
        'apply' {
            if (-not (Test-Administrator)) { throw 'Run Partly 20 as administrator to apply disk changes.' }
            $operations = @($request.operations)
            if ($operations.Count -lt 1 -or $operations.Count -gt 100) { throw 'Queue between 1 and 100 operations.' }
            Assert-Snapshot $request
            $ids = @{}
            foreach ($operation in $operations) {
                if ([string]::IsNullOrWhiteSpace([string]$operation.id) -or $ids.ContainsKey([string]$operation.id)) { throw 'Every operation must have a unique ID.' }
                $ids[[string]$operation.id] = $true
                Assert-Operation $operation $true
            }
            # Recheck the complete snapshot after preflight, before the first write.
            Assert-Snapshot $request
            $index = 0
            foreach ($operation in $operations) {
                if ($request.cancelPath -and (Test-Path -LiteralPath $request.cancelPath)) { throw 'Cancelled before starting the next operation. Completed disk changes were preserved.' }
                $script:CurrentOperation = @{ id = [string]$operation.id; type = [string]$operation.type; diskNumber = [int]$operation.diskNumber; status = 'started' }
                Write-OperationProgress $operation 'running' $index $operations.Count
                Assert-Operation $operation $false
                Invoke-StorageOperation $operation
                $script:CurrentOperation.status = 'completed'
                $script:Applied.Add($script:CurrentOperation)
                $index++
                Write-OperationProgress $operation 'completed' $index $operations.Count
                $script:CurrentOperation = $null
            }
            $result = @{ success = $true; completed = @($script:Applied.ToArray()); failedOperation = $null; inventory = Get-Inventory }
        }
    }
    $result | ConvertTo-Json -Depth 15 -Compress | Write-Output
    exit 0
} catch {
    $errorInfo = @{ code = 'WINDOWS_STORAGE_ERROR'; message = $_.Exception.Message }
    if ($Action -eq 'apply') {
        if ($script:CurrentOperation) { $script:CurrentOperation.status = 'failed'; $script:CurrentOperation.error = $_.Exception.Message }
        $inventory = $null
        try { $inventory = Get-Inventory } catch { }
        @{ success = $false; completed = @($script:Applied.ToArray()); failedOperation = $script:CurrentOperation; error = $errorInfo; inventory = $inventory; requiresRefresh = $true } | ConvertTo-Json -Depth 15 -Compress | Write-Output
    } else { @{ error = $errorInfo } | ConvertTo-Json -Depth 5 -Compress | Write-Output }
    exit 1
}
