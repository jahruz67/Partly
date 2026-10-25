param(
    [Parameter(Mandatory = $true)][ValidateSet('scan', 'recover', 'inspect-fixture')][string]$Action,
    [Parameter(Mandatory = $true)][string]$PayloadPath,
    [string]$CancelPath = ''
)

# Native reads use only GENERIC_READ. Recovery writes only the partition table using
# New-Partition; it deliberately never formats or manufactures file-system data.
# References: Microsoft exFAT specification and New-Partition documentation.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:CreatedPartition = $null

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Partly20Recovery {
    public interface IReader : IDisposable { int SectorSize { get; } byte[] ReadAt(long offset, int count); }

    public sealed class RawReader : IReader {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetFilePointerEx(SafeFileHandle handle, long offset, out long position, uint method);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool ReadFile(SafeFileHandle handle, IntPtr buffer, uint count, out uint read, IntPtr overlapped);
        private SafeFileHandle handle;
        private IntPtr allocation, aligned;
        private readonly long length;
        public int SectorSize { get; private set; }
        public RawReader(int number, int sectorSize, long diskLength) {
            if (number < 0 || !BootParser.ValidSector(sectorSize) || diskLength < 2097152) throw new ArgumentException("Invalid disk geometry.");
            SectorSize = sectorSize; length = diskLength;
            handle = CreateFileW(@"\\.\PhysicalDrive" + number, 0x80000000, 3, IntPtr.Zero, 3, 0x20000000, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not open the disk for a read-only recovery scan.");
            allocation = Marshal.AllocHGlobal(1048576 + 4095);
            aligned = new IntPtr((allocation.ToInt64() + 4095) & ~4095L);
        }
        public byte[] ReadAt(long offset, int count) {
            if (offset < 0 || count < SectorSize || count > 1048576 || offset % SectorSize != 0 || count % SectorSize != 0 || offset > length - count) throw new IOException("Recovery read exceeds the selected disk or is not sector aligned.");
            long position; uint read;
            if (!SetFilePointerEx(handle, offset, out position, 0) || position != offset) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to seek to a recovery scan sector.");
            if (!ReadFile(handle, aligned, (uint)count, out read, IntPtr.Zero) || read != (uint)count) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read a recovery scan sector.");
            byte[] data = new byte[count]; Marshal.Copy(aligned, data, 0, count); return data;
        }
        public void Dispose() {
            if (handle != null) { handle.Dispose(); handle = null; }
            if (allocation != IntPtr.Zero) { Marshal.FreeHGlobal(allocation); allocation = IntPtr.Zero; }
        }
    }

    // Fixture readers are memory-only. Tests can exercise actual native header parsing
    // and scanning without opening any user's disk or requiring administrator access.
    public sealed class MemoryReader : IReader {
        private readonly SortedDictionary<long, byte[]> blocks = new SortedDictionary<long, byte[]>();
        private readonly long length;
        public int SectorSize { get; private set; }
        public MemoryReader(long size, int sectorSize) { length = size; SectorSize = sectorSize; }
        public void Add(long offset, byte[] data) { blocks.Add(offset, data); }
        public byte[] ReadAt(long offset, int count) {
            if (offset < 0 || count < 1 || offset > length - count) throw new IOException("Fixture read out of range.");
            byte[] result = new byte[count];
            foreach (KeyValuePair<long, byte[]> block in blocks) {
                long start = Math.Max(offset, block.Key), end = Math.Min(offset + count, block.Key + block.Value.Length);
                if (end > start) Buffer.BlockCopy(block.Value, (int)(start - block.Key), result, (int)(start - offset), (int)(end - start));
            }
            return result;
        }
        public void Dispose() { }
    }

    public sealed class Candidate {
        public long offset, size;
        public int bytesPerSector;
        public string fileSystem, label, confidence, bootHash;
        public bool backupVerified, metadataVerified, recoverable;
        public long backupOffset = -1;
        internal long sectors, metadataSector, alternateSize;
    }
    public sealed class Progress {
        public long scannedBytes, totalBytes;
        public int candidates;
        public double percent;
        public string message;
    }
    public sealed class ScanResult {
        public bool success = true, cancelled, truncated;
        public string message;
        public long scannedBytes, totalBytes;
        public int readErrorCount;
        public List<string> readErrors = new List<string>();
        public List<Candidate> candidates = new List<Candidate>();
    }

    public static class BootParser {
        public static bool ValidSector(int size) { return size == 512 || size == 1024 || size == 2048 || size == 4096; }
        private static bool PowerTwo(int number) { return number > 0 && (number & (number - 1)) == 0; }
        private static ushort U16(byte[] data, int index) { return BitConverter.ToUInt16(data, index); }
        private static uint U32(byte[] data, int index) { return BitConverter.ToUInt32(data, index); }
        private static ulong U64(byte[] data, int index) { return BitConverter.ToUInt64(data, index); }
        private static string Text(byte[] data, int index, int length) { return Encoding.ASCII.GetString(data, index, length); }
        private static bool BootSignature(byte[] data) { return data != null && data.Length >= 512 && data[510] == 0x55 && data[511] == 0xAA && (data[0] == 0xEB || data[0] == 0xE9); }
        private static string Hash(byte[] data, int count) { using (SHA256 hash = SHA256.Create()) { return BitConverter.ToString(hash.ComputeHash(data, 0, count)).Replace("-", "").ToLowerInvariant(); } }
        public static bool LooksLike(byte[] data, int index) {
            if (data == null || index < 0 || index > data.Length - 512 || data[index + 510] != 0x55 || data[index + 511] != 0xAA) return false;
            if (data[index] != 0xEB && data[index] != 0xE9) return false;
            return Text(data, index + 3, 8) == "NTFS    " || Text(data, index + 3, 8) == "EXFAT   " || Text(data, index + 54, 3) == "FAT" || Text(data, index + 82, 5) == "FAT32";
        }
        public static Candidate Parse(byte[] data, long offset, long available, int diskSectorSize) {
            if (!BootSignature(data) || offset < 1048576 || available < 1048576 || offset % diskSectorSize != 0) return null;
            Candidate result = new Candidate(); result.offset = offset; result.label = "";
            string oem = Text(data, 3, 8);
            long totalSectors = 0; int bps = 0;
            if (oem == "EXFAT   ") {
                for (int index = 11; index < 64; index++) if (data[index] != 0) return null;
                int shift = data[108], clusterShift = data[109], fats = data[110];
                if (shift < 9 || shift > 12 || clusterShift > 25 - shift || (fats != 1 && fats != 2) || U16(data, 104) != 0x0100 || (data[112] > 100 && data[112] != 255)) return null;
                bps = 1 << shift;
                ulong volumeLength = U64(data, 72), partitionOffset = U64(data, 64);
                if (volumeLength > (ulong)long.MaxValue / (ulong)bps || volumeLength < (ulong)(1048576 / bps) || (partitionOffset != 0 && partitionOffset != (ulong)(offset / bps))) return null;
                uint fatOffset = U32(data, 80), fatLength = U32(data, 84), heapOffset = U32(data, 88), clusters = U32(data, 92), root = U32(data, 96);
                if (fatOffset < 24 || fatLength == 0 || clusters < 1 || clusters > 0xFFFFFFF5U || root < 2 || (ulong)root >= (ulong)clusters + 2 || (ulong)heapOffset < (ulong)fatOffset + (ulong)fatLength * (ulong)fats) return null;
                if ((ulong)heapOffset + ((ulong)clusters << clusterShift) > volumeLength || (ulong)fatLength * (ulong)bps < ((ulong)clusters + 2) * 4) return null;
                result.fileSystem = "exFAT"; totalSectors = (long)volumeLength; result.metadataSector = fatOffset; result.backupOffset = offset + 12L * bps;
            } else {
                bps = U16(data, 11); int spc = data[13];
                if (!ValidSector(bps) || !PowerTwo(spc) || spc > 128 || bps * spc > 2097152) return null;
                if (oem == "NTFS    ") {
                    if (U16(data, 14) != 0 || data[16] != 0 || U16(data, 17) != 0 || U16(data, 19) != 0 || U16(data, 22) != 0 || U32(data, 32) != 0) return null;
                    ulong sectors = U64(data, 40), mft = U64(data, 48), mirror = U64(data, 56);
                    if (sectors < (ulong)(1048576 / bps) || sectors >= (ulong)long.MaxValue / (ulong)bps || mft == 0 || mft > sectors / (ulong)spc || mirror == 0 || mirror > sectors / (ulong)spc) return null;
                    uint hidden = U32(data, 28);
                    if (hidden != 0 && hidden != (uint)(offset / bps)) return null;
                    // Modern NTFS stores the last sector index in its total-sector field.
                    // Both conventions are accepted only after checking their backup position.
                    totalSectors = (long)sectors + 1; result.alternateSize = (long)sectors * bps;
                    result.fileSystem = "NTFS"; result.metadataSector = (long)mft * spc; result.backupOffset = offset + (long)sectors * bps;
                } else {
                    int reserved = U16(data, 14), fats = data[16], rootEntries = U16(data, 17);
                    uint fatSize = U16(data, 22); if (fatSize == 0) fatSize = U32(data, 36);
                    totalSectors = U16(data, 19); if (totalSectors == 0) totalSectors = U32(data, 32);
                    long rootSectors = ((long)rootEntries * 32 + bps - 1) / bps;
                    long dataSectors = totalSectors - reserved - (long)fats * fatSize - rootSectors;
                    if (reserved < 1 || (fats != 1 && fats != 2) || fatSize == 0 || dataSectors <= 0 || (data[21] != 0xF0 && data[21] < 0xF8)) return null;
                    long clusters = dataSectors / spc;
                    result.fileSystem = clusters < 4085 ? "FAT12" : clusters < 65525 ? "FAT16" : "FAT32";
                    long fatBytesRequired = result.fileSystem == "FAT12" ? ((clusters + 2) * 3 + 1) / 2 : (clusters + 2) * (result.fileSystem == "FAT16" ? 2 : 4);
                    if ((long)fatSize * bps < fatBytesRequired) return null;
                    uint hidden = U32(data, 28);
                    if (hidden != 0 && hidden != (uint)(offset / bps)) return null;
                    if (result.fileSystem == "FAT32") {
                        uint root = U32(data, 44); int backup = U16(data, 50);
                        if (U16(data, 22) != 0 || rootEntries != 0 || root < 2 || root >= clusters + 2 || Text(data, 82, 8) != "FAT32   " || U16(data, 42) != 0) return null;
                        result.label = Text(data, 71, 11).Trim();
                        if (backup > 0 && backup < reserved) result.backupOffset = offset + (long)backup * bps;
                    } else {
                        if (rootEntries == 0 || U16(data, 22) == 0 || Text(data, 54, 8) != result.fileSystem.PadRight(8)) return null;
                        result.label = Text(data, 43, 11).Trim();
                    }
                    if (result.label == "NO NAME") result.label = "";
                    result.metadataSector = reserved;
                }
            }
            if (!ValidSector(bps) || bps != diskSectorSize || data.Length < bps || offset % bps != 0 || totalSectors <= 0 || totalSectors > long.MaxValue / bps) return null;
            result.bytesPerSector = bps; result.sectors = totalSectors; result.size = totalSectors * bps;
            if (result.size > available && result.alternateSize >= 1048576 && result.alternateSize <= available) result.size = result.alternateSize;
            if (result.size < 1048576 || result.size > available) return null;
            result.bootHash = Hash(data, bps); result.confidence = "Medium";
            return result;
        }
        private static bool SameBoot(byte[] main, byte[] backup, string fileSystem) {
            if (!BootSignature(backup)) return false;
            int end = fileSystem == "NTFS" ? 84 : fileSystem == "exFAT" ? 113 : fileSystem == "FAT32" ? 90 : 62;
            for (int index = 3; index < end; index++) {
                if (fileSystem == "exFAT" && (index == 106 || index == 107 || index == 112)) continue;
                if (main[index] != backup[index]) return false;
            }
            return true;
        }
        private static bool ExfatChecksum(byte[] region, int bps) {
            if (region.Length != bps * 12) return false;
            uint checksum = 0;
            for (int index = 0; index < 11 * bps; index++) {
                if (index == 106 || index == 107 || index == 112) continue;
                checksum = unchecked(((checksum & 1) != 0 ? 0x80000000U : 0) + (checksum >> 1) + region[index]);
            }
            for (int index = 11 * bps; index < 12 * bps; index += 4) if (U32(region, index) != checksum) return false;
            return true;
        }
        private static bool ValidMftRecord(byte[] record, int bps) {
            if (record.Length < 48 || Text(record, 0, 4) != "FILE") return false;
            int usaOffset = U16(record, 4), usaCount = U16(record, 6), attributeOffset = U16(record, 20);
            uint used = U32(record, 24), allocated = U32(record, 28);
            if (usaOffset < 42 || usaOffset + usaCount * 2 > record.Length || usaCount < 2 || allocated < bps || allocated > 1048576 || !PowerTwo((int)allocated) || used > allocated || used < 48 || attributeOffset < 42 || attributeOffset >= used) return false;
            return usaCount == allocated / bps + 1;
        }
        public static Candidate Probe(IReader reader, long offset, long available) {
            int bps = reader.SectorSize;
            byte[] boot = reader.ReadAt(offset, bps);
            Candidate result = Parse(boot, offset, available, bps);
            if (result == null) return null;
            if (result.fileSystem == "exFAT") {
                if (!ExfatChecksum(reader.ReadAt(offset, 12 * bps), bps)) return null;
            }
            if (result.backupOffset >= offset && result.backupOffset <= offset + available - bps) {
                try {
                    byte[] backup = reader.ReadAt(result.backupOffset, bps);
                    result.backupVerified = SameBoot(boot, backup, result.fileSystem);
                    if (result.fileSystem == "exFAT" && result.backupVerified) result.backupVerified = ExfatChecksum(reader.ReadAt(result.backupOffset, 12 * bps), bps);
                } catch (IOException) { } catch (Win32Exception) { }
            }
            if (result.fileSystem == "NTFS" && !result.backupVerified && result.alternateSize >= 1048576) {
                long alternateBackup = offset + result.alternateSize - bps;
                if (alternateBackup <= offset + available - bps) {
                    try {
                        if (SameBoot(boot, reader.ReadAt(alternateBackup, bps), result.fileSystem)) { result.size = result.alternateSize; result.backupOffset = alternateBackup; result.backupVerified = true; }
                    } catch (IOException) { } catch (Win32Exception) { }
                }
            }
            long metadataOffset = offset + result.metadataSector * bps;
            if (metadataOffset >= offset && metadataOffset <= offset + result.size - bps) {
                try {
                    byte[] metadata = reader.ReadAt(metadataOffset, bps);
                    result.metadataVerified = result.fileSystem == "NTFS" ? ValidMftRecord(metadata, bps) : result.fileSystem == "exFAT" ? U32(metadata, 0) >= 0xFFFFFFF8U && U32(metadata, 4) == 0xFFFFFFFFU : metadata[0] == boot[21] && metadata[1] == 0xFF && metadata[2] == 0xFF;
                } catch (IOException) { } catch (Win32Exception) { }
            }
            if (result.backupVerified || result.metadataVerified) result.confidence = "High";
            result.recoverable = result.backupVerified || result.metadataVerified;
            return result;
        }
        public static ScanResult Scan(IReader reader, long offset, long length, bool deep, string cancelPath, Action<Progress> progress) {
            ScanResult result = new ScanResult(); result.totalBytes = length;
            int sectorSize = reader.SectorSize;
            if (offset < 1048576 || offset % sectorSize != 0 || length < sectorSize || length % sectorSize != 0 || offset > long.MaxValue - length) throw new ArgumentException("Invalid unallocated recovery range.");
            long end = offset + length, cursor = offset;
            long stride = deep ? sectorSize : 1048576;
            Stopwatch clock = Stopwatch.StartNew(); long lastProgress = -1000;
            while (cursor <= end - sectorSize) {
                if (!String.IsNullOrEmpty(cancelPath) && File.Exists(cancelPath)) { result.cancelled = true; break; }
                long blockStart = cursor; int count = deep ? (int)Math.Min(1048576, end - cursor) : sectorSize;
                byte[] data = null;
                try { data = reader.ReadAt(blockStart, count); }
                catch (Exception error) {
                    if (!(error is IOException) && !(error is Win32Exception)) throw;
                    result.readErrorCount++; if (result.readErrors.Count < 16) result.readErrors.Add("Offset " + cursor + ": " + error.Message);
                }
                if (data != null) {
                    for (int index = 0; index <= data.Length - sectorSize; index += sectorSize) {
                        if (!deep && index != 0) break;
                        if (!LooksLike(data, index)) continue;
                        long location = blockStart + index;
                        try {
                            Candidate candidate = Probe(reader, location, end - location);
                            if (candidate != null) {
                                bool duplicate = false;
                                foreach (Candidate found in result.candidates) if (found.offset == candidate.offset) { duplicate = true; break; }
                                if (!duplicate) result.candidates.Add(candidate);
                                if (result.candidates.Count >= 256) { result.truncated = true; break; }
                            }
                        } catch (Exception error) {
                            if (!(error is IOException) && !(error is Win32Exception)) throw;
                            result.readErrorCount++; if (result.readErrors.Count < 16) result.readErrors.Add("Offset " + location + ": " + error.Message);
                        }
                    }
                }
                long advanced = deep ? count : stride;
                if (!deep && cursor == offset && offset % stride != 0) advanced = stride - offset % stride;
                cursor = Math.Min(end, cursor + advanced); result.scannedBytes = cursor - offset;
                if (progress != null && (clock.ElapsedMilliseconds - lastProgress >= 500 || cursor >= end || result.truncated)) {
                    progress(new Progress { scannedBytes = result.scannedBytes, totalBytes = length, candidates = result.candidates.Count, percent = 100.0 * result.scannedBytes / length, message = deep ? "Scanning every sector for lost volumes…" : "Scanning aligned volume headers…" });
                    lastProgress = clock.ElapsedMilliseconds;
                }
                if (result.truncated) break;
            }
            result.message = result.cancelled ? "Recovery scan cancelled." : result.truncated ? "The scan found 256 candidates and stopped. Scan a smaller range to inspect more volumes." : "Recovery scan completed: " + result.candidates.Count + " candidate volume(s) found.";
            return result;
        }
    }
}
'@

function Assert-Whole($Value, [string]$Name, [long]$Minimum = 0) {
    if ($null -eq $Value -or [string]$Value -notmatch '^\d+$') { throw "$Name must be a whole number." }
    $number = [long]$Value
    if ($number -lt $Minimum -or $number -gt 9007199254740991) { throw "$Name is out of range." }
    return $number
}
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Letter($Value) {
    if ([string]$Value -eq [string][char]0) { return '' }
    return ([string]$Value).Trim().ToUpperInvariant()
}
function Get-CurrentPartitions($Disk) {
    # Get-Partition can report ObjectNotFound on a valid GPT disk with no entries.
    if ([int]$Disk.NumberOfPartitions -eq 0) { return @() }
    return @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop)
}
function Get-TargetDisk($Target, [bool]$Writing = $false) {
    $number = Assert-Whole $Target.diskNumber 'Disk number'
    if ([string]::IsNullOrWhiteSpace([string]$Target.diskUniqueId)) { throw 'Disk identity is required.' }
    $disk = Get-Disk -Number $number -ErrorAction Stop
    if ([string]$disk.UniqueId -cne [string]$Target.diskUniqueId) { throw 'The disk identity changed. Refresh and scan again.' }
    if ($disk.IsOffline) { throw 'Bring the disk online before scanning for lost volumes.' }
    if ([string]$disk.PartitionStyle -notin @('GPT', 'MBR')) { throw 'Lost volume recovery requires an existing GPT or MBR disk.' }
    if ([string]$disk.BusType -eq 'Spaces' -or $disk.IsClustered) { throw 'Recovery is unavailable on Storage Spaces or clustered disks.' }
    if ($Writing) {
        if ($disk.IsBoot -or $disk.IsSystem) { throw 'Recovery does not change Windows boot or system disks.' }
        if ($disk.IsReadOnly -or [string]$disk.HealthStatus -ne 'Healthy') { throw 'Recovery requires a healthy, writable disk.' }
        if (@(Get-CurrentPartitions $disk | Where-Object { $_.IsBoot -or $_.IsSystem }).Count -gt 0) { throw 'Recovery does not change disks containing Windows boot or system partitions.' }
    }
    return $disk
}
function Get-SectorSize($Disk) {
    $size = [int]$Disk.LogicalSectorSize
    if ($size -notin @(512, 1024, 2048, 4096)) { throw 'The disk logical sector size is unsupported.' }
    return $size
}
function Assert-FreeRange($Disk, [long]$Offset, [long]$Size) {
    $sector = Get-SectorSize $Disk
    if ($Offset -lt 1048576 -or $Size -lt $sector -or $Offset % $sector -ne 0 -or $Size % $sector -ne 0 -or $Offset -gt [long]$Disk.Size - 1048576 - $Size) { throw 'Recovery range crosses disk metadata or is not sector aligned.' }
    foreach ($partition in @(Get-CurrentPartitions $Disk)) {
        if ($Offset -lt [long]$partition.Offset + [long]$partition.Size -and $Offset + $Size -gt [long]$partition.Offset) { throw 'The requested recovery range overlaps an existing partition. Refresh and scan current unallocated space.' }
    }
}
function Assert-Snapshot($Request, $Disk) {
    if ($null -eq $Request.expectedSnapshot -or $null -eq $Request.expectedSnapshot.disks) { throw 'A current disk snapshot is required.' }
    $expected = @($Request.expectedSnapshot.disks | Where-Object { [int]$_.number -eq [int]$Disk.Number })
    if ($expected.Count -ne 1) { throw 'The recovery disk is missing from the snapshot.' }
    $before = $expected[0]
    if ([string]$before.uniqueId -cne [string]$Disk.UniqueId -or [long]$before.size -ne [long]$Disk.Size -or [string]$before.partitionStyle -cne [string]$Disk.PartitionStyle -or ([string]$before.serialNumber).Trim() -cne ([string]$Disk.SerialNumber).Trim()) { throw 'The recovery disk changed. Refresh and scan again.' }
    $actual = @(Get-CurrentPartitions $Disk)
    if (@($before.partitions).Count -ne $actual.Count) { throw 'The disk partition layout changed. Refresh and scan again.' }
    foreach ($partition in $actual) {
        $old = @($before.partitions | Where-Object { [int]$_.partitionNumber -eq [int]$partition.PartitionNumber })
        if ($old.Count -ne 1 -or [long]$old[0].offset -ne [long]$partition.Offset -or [long]$old[0].size -ne [long]$partition.Size -or (Letter $old[0].driveLetter) -cne (Letter $partition.DriveLetter)) { throw 'A partition changed. Refresh and scan again.' }
    }
}
function Send-Progress($Value) { [Console]::Error.WriteLine('PARTLY20_RECOVERY:' + ($Value | ConvertTo-Json -Depth 8 -Compress)) }

try {
    $request = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
    if ($Action -eq 'inspect-fixture') {
        $cases = $(if ($request.cases) { @($request.cases) } else { @($request) })
        $results = @(foreach ($case in $cases) {
            $reader = New-Object Partly20Recovery.MemoryReader([long]$case.diskSize, [int]$case.sectorSize)
            try {
                foreach ($block in @($case.blocks)) { $reader.Add([long]$block.offset, [Convert]::FromBase64String([string]$block.data)) }
                if ($case.scan) { $fixtureResult = [Partly20Recovery.BootParser]::Scan($reader, [long]$case.offset, [long]$case.length, [bool]$case.deepScan, $CancelPath, $null) }
                else { $fixtureResult = [Partly20Recovery.BootParser]::Probe($reader, [long]$case.offset, [long]$case.length) }
                @{ id = $case.id; result = $fixtureResult }
            } finally { $reader.Dispose() }
        })
        @{ results = $results } | ConvertTo-Json -Depth 12 -Compress | Write-Output
        exit 0
    }
    Import-Module Storage -ErrorAction Stop
    if (-not (Test-Administrator)) { throw 'Run Partly 20 as administrator to scan raw disks or recover a volume.' }
    $disk = Get-TargetDisk $request.target ($Action -eq 'recover')
    $sectorSize = Get-SectorSize $disk
    if ($Action -eq 'scan') {
        $offset = Assert-Whole $request.params.offset 'Scan offset' 1048576
        $length = Assert-Whole $request.params.length 'Scan length' $sectorSize
        if ($null -ne $request.params.deepScan -and $request.params.deepScan -isnot [bool]) { throw 'Deep scan must be true or false.' }
        Assert-FreeRange $disk $offset $length
        $reader = New-Object Partly20Recovery.RawReader([int]$disk.Number, $sectorSize, [long]$disk.Size)
        try {
            $callback = [Action[Partly20Recovery.Progress]]{ param($value) Send-Progress $value }
            $result = [Partly20Recovery.BootParser]::Scan($reader, $offset, $length, [bool]$request.params.deepScan, $CancelPath, $callback)
        } finally { $reader.Dispose() }
    } else {
        Assert-Snapshot $request $disk
        $candidate = $request.params.candidate
        $offset = Assert-Whole $candidate.offset 'Candidate offset' 1048576
        $size = Assert-Whole $candidate.size 'Candidate size' 1048576
        if ([string]$candidate.fileSystem -cnotin @('NTFS', 'FAT12', 'FAT16', 'FAT32', 'exFAT') -or [string]$candidate.bootHash -notmatch '^[a-fA-F0-9]{64}$' -or [int]$candidate.bytesPerSector -ne $sectorSize) { throw 'Candidate evidence is invalid. Run the recovery scan again.' }
        Assert-FreeRange $disk $offset $size
        if ([string]$disk.PartitionStyle -eq 'MBR' -and $offset + $size -gt 2199023255552) { throw 'This volume exceeds the MBR 2 TiB limit.' }
        $letter = [string]$request.params.driveLetter
        if ($letter -cnotmatch '^[A-Z]?$') { throw 'Choose a drive letter from A to Z or no drive letter.' }
        if ($letter) {
            if (@(Get-Partition -ErrorAction Stop | Where-Object { (Letter $_.DriveLetter) -eq $letter }).Count -gt 0 -or (Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue)) { throw "Drive letter $letter is already in use." }
        }
        Send-Progress @{ percent = 10; message = 'Verifying the detected volume and current free space…'; cancellable = $true }
        $reader = New-Object Partly20Recovery.RawReader([int]$disk.Number, $sectorSize, [long]$disk.Size)
        try { $verified = [Partly20Recovery.BootParser]::Probe($reader, $offset, $size) } finally { $reader.Dispose() }
        if ($null -eq $verified -or $verified.offset -ne $offset -or $verified.size -ne $size -or $verified.fileSystem -cne [string]$candidate.fileSystem -or $verified.bootHash -ine [string]$candidate.bootHash) { throw 'The lost volume header changed or no longer matches its scan evidence. Nothing was recovered.' }
        if (-not $verified.recoverable) { throw 'Only a boot header was found; neither a matching backup boot sector nor valid file-system metadata could be verified. Recovering this ambiguous candidate is not supported.' }
        # Revalidate live identity and complete geometry after the raw verification and
        # immediately before adding a partition-table entry. No formatting is performed.
        $disk = Get-TargetDisk $request.target $true
        Assert-Snapshot $request $disk
        Assert-FreeRange $disk $offset $size
        if ($CancelPath -and (Test-Path -LiteralPath $CancelPath)) {
            @{ success = $false; cancelled = $true; message = 'Volume recovery cancelled before any partition changes.' } | ConvertTo-Json -Compress | Write-Output
            exit 0
        }
        $parameters = @{ DiskNumber = [int]$disk.Number; Offset = $offset; Size = $size; Alignment = [uint32]$sectorSize; IsHidden = $true; ErrorAction = 'Stop' }
        if ([string]$disk.PartitionStyle -eq 'GPT') { $parameters.GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' }
        else { $parameters.MbrType = $(if ([string]$verified.fileSystem -in @('FAT12', 'FAT16', 'FAT32')) { [string]$verified.fileSystem } else { 'IFS' }) }
        Send-Progress @{ percent = 40; message = 'Restoring the detected partition entry without formatting…'; cancellable = $false }
        $created = New-Partition @parameters
        $script:CreatedPartition = [int]$created.PartitionNumber
        if ([long]$created.Offset -ne $offset -or [long]$created.Size -ne $size) { throw 'Windows created a different partition geometry. The partition was left hidden; inspect the disk before continuing.' }
        $reader = New-Object Partly20Recovery.RawReader([int]$disk.Number, $sectorSize, [long]$disk.Size)
        try { $preserved = [Partly20Recovery.BootParser]::Probe($reader, $offset, $size) } finally { $reader.Dispose() }
        if ($null -eq $preserved -or $preserved.bootHash -ine [string]$candidate.bootHash) { throw 'The volume boot-sector verification failed after restoring its partition entry. The partition remains hidden; no formatting was attempted.' }
        Send-Progress @{ percent = 80; message = 'Boot sector preserved. Making the recovered volume available…'; cancellable = $false }
        $created | Set-Partition -IsHidden:$false -Confirm:$false -ErrorAction Stop | Out-Null
        if ($letter) { Get-Partition -DiskNumber $disk.Number -PartitionNumber $created.PartitionNumber -ErrorAction Stop | Set-Partition -NewDriveLetter ([char]$letter) -Confirm:$false -ErrorAction Stop | Out-Null }
        $result = @{ success = $true; diskNumber = [int]$disk.Number; partitionNumber = [int]$created.PartitionNumber; offset = $offset; size = $size; fileSystem = $verified.fileSystem; driveLetter = $letter; bootSectorPreserved = $true; formatted = $false; message = 'The existing volume partition entry was restored without formatting.' }
        Send-Progress @{ percent = 100; message = 'Volume recovery completed.'; cancellable = $true }
    }
    $result | ConvertTo-Json -Depth 12 -Compress | Write-Output
    exit 0
} catch {
    @{ error = @{ code = 'RECOVERY_STORAGE_ERROR'; message = $_.Exception.Message }; createdPartitionNumber = $script:CreatedPartition; requiresRefresh = ($null -ne $script:CreatedPartition) } | ConvertTo-Json -Depth 6 -Compress | Write-Output
    exit 1
}
