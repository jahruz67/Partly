# Pure native helper compilation/fixture checks. This script never opens a physical disk or calls an I/O control.
$ErrorActionPreference = 'Stop'
$nativeTokens = $null; $nativeErrors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../windows/advanced-storage.ps1'), [ref]$nativeTokens, [ref]$nativeErrors)
if ($nativeErrors.Count) { throw ($nativeErrors.Message -join '; ') }
$assignment = $tree.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$nativeSource' }, $true)
$source = $assignment.Right.Expression.Value
if (-not $source) { throw 'Native helper source was not found.' }
Add-Type -TypeDefinition $source -Language CSharp

function Assert-Equal($Expected, $Actual, $Name) { if ($Expected -ne $Actual) { throw "$Name expected $Expected, got $Actual" } }

[byte[]]$ntfs = New-Object byte[] 512
[Text.Encoding]::ASCII.GetBytes('NTFS    ').CopyTo($ntfs, 3)
[BitConverter]::GetBytes([uint16]512).CopyTo($ntfs, 11)
$ntfs[510] = 0x55; $ntfs[511] = 0xaa
[byte[]]$serial = @(1, 2, 3, 4, 5, 6, 7, 8)
$patchedNtfs = [PartlyDiskIo]::PatchBootRegion($ntfs, 'NTFS', 1048576, 512, $serial)
Assert-Equal 2048 ([BitConverter]::ToUInt32($patchedNtfs, 28)) 'NTFS hidden sectors'
Assert-Equal '0102030405060708' ([BitConverter]::ToString($patchedNtfs[72..79]).Replace('-', '')) 'NTFS new serial'
Assert-Equal 0 ([BitConverter]::ToUInt32($ntfs, 28)) 'NTFS original fixture remains unchanged'

[byte[]]$fat = New-Object byte[] (24 * 512)
[BitConverter]::GetBytes([uint16]512).CopyTo($fat, 11)
[BitConverter]::GetBytes([uint16]6).CopyTo($fat, 50)
$fat[510] = 0x55; $fat[511] = 0xaa
$fat[6 * 512 + 510] = 0x55; $fat[6 * 512 + 511] = 0xaa
$patchedFat = [PartlyDiskIo]::PatchBootRegion($fat, 'FAT32', 2MB, 512, [byte[]]@(1, 2, 3, 4))
Assert-Equal 4096 ([BitConverter]::ToUInt32($patchedFat, 28)) 'FAT32 primary offset'
Assert-Equal 4096 ([BitConverter]::ToUInt32($patchedFat, 6 * 512 + 28)) 'FAT32 backup offset'
Assert-Equal 67305985 ([BitConverter]::ToUInt32($patchedFat, 6 * 512 + 67)) 'FAT32 backup serial'

[byte[]]$exfat = New-Object byte[] (24 * 512)
foreach ($start in @(0, (12 * 512))) {
    [Text.Encoding]::ASCII.GetBytes('EXFAT   ').CopyTo($exfat, $start + 3)
    $exfat[$start + 108] = 9; $exfat[$start + 510] = 0x55; $exfat[$start + 511] = 0xaa
}
$patchedExfat = [PartlyDiskIo]::PatchBootRegion($exfat, 'exFAT', 3MB, 512, [byte[]]@(1, 2, 3, 4))
Assert-Equal 6144 ([BitConverter]::ToUInt64($patchedExfat, 64)) 'exFAT primary offset'
Assert-Equal 6144 ([BitConverter]::ToUInt64($patchedExfat, 12 * 512 + 64)) 'exFAT backup offset'
$checksum = [BitConverter]::ToUInt32($patchedExfat, 11 * 512)
Assert-Equal $checksum ([BitConverter]::ToUInt32($patchedExfat, 12 * 512 + 11 * 512)) 'exFAT primary and backup checksums'
for ($offset = 11 * 512; $offset -lt 12 * 512; $offset += 4) { Assert-Equal $checksum ([BitConverter]::ToUInt32($patchedExfat, $offset)) 'exFAT checksum sector repetition' }
$skipFields = [byte[]]$patchedExfat[0..(11 * 512 - 1)]
$before = [PartlyDiskIo]::ExFatChecksum($skipFields, 512)
$skipFields[106] = 123; $skipFields[107] = 45; $skipFields[112] = 67
Assert-Equal $before ([PartlyDiskIo]::ExFatChecksum($skipFields, 512)) 'exFAT checksum excludes mutable flags'

[byte[]]$layout = New-Object byte[] (48 + 144 * 2)
[BitConverter]::GetBytes([int]1).CopyTo($layout, 0)
[BitConverter]::GetBytes([int]2).CopyTo($layout, 4)
foreach ($entry in @(48, (48 + 144))) { [BitConverter]::GetBytes([int]1).CopyTo($layout, $entry) }
[BitConverter]::GetBytes([long]1MB).CopyTo($layout, 48 + 8)
[BitConverter]::GetBytes([long]10MB).CopyTo($layout, 48 + 16)
[BitConverter]::GetBytes([uint32]1).CopyTo($layout, 48 + 24)
[BitConverter]::GetBytes([long]30MB).CopyTo($layout, 48 + 144 + 8)
[BitConverter]::GetBytes([long]10MB).CopyTo($layout, 48 + 144 + 16)
[BitConverter]::GetBytes([uint32]2).CopyTo($layout, 48 + 144 + 24)
$moved = [PartlyDiskIo]::ProjectMoveLayout($layout, 1, 1MB, 10MB, 15MB, 512)
Assert-Equal 15MB ([BitConverter]::ToInt64($moved, 48 + 8)) 'GPT projected move position'
Assert-Equal 1 $moved[48 + 28] 'GPT rewrite flag'
Assert-Equal 30MB ([BitConverter]::ToInt64($moved, 48 + 144 + 8)) 'Unrelated partition remains unchanged'
$overlapRejected = $false
try { [void][PartlyDiskIo]::ProjectMoveLayout($layout, 1, 1MB, 10MB, 25MB, 512) } catch { $overlapRejected = $true }
Assert-Equal $true $overlapRejected 'Native layout rejects overlapping move'
Write-Output 'Native helper compiled; NTFS/FAT32/exFAT pure boot-record fixtures passed. No device was opened.'
