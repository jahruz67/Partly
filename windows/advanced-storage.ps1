param(
    [Parameter(Mandatory = $true)][ValidateSet('surface', 'sectors', 'writeSectors', 'move', 'copy', 'convert')][string]$Action,
    [Parameter(Mandatory = $true)][string]$PayloadPath,
    [string]$CancellationFile
)

# Advanced local device operations. All target identifiers are data, never executable command text.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:RecoveryPath = $null
$script:CreatedPartition = $null

$nativeSource = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public sealed class PartlyScanError { public long Sector; public int ErrorCode; public string Message; }
public sealed class PartlyScanResult { public long TotalBytes; public long ScannedBytes; public long BadSectors; public bool Cancelled; public List<PartlyScanError> Errors = new List<PartlyScanError>(); }
public static class PartlyDiskIo {
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, SHARE = 3, OPEN_EXISTING = 3;
    const uint FSCTL_LOCK_VOLUME = 0x90018, FSCTL_DISMOUNT_VOLUME = 0x90020;
    const uint GET_LAYOUT = 0x70050, SET_LAYOUT = 0x7c054, UPDATE_PROPERTIES = 0x70140;
    const int CHUNK = 4 * 1024 * 1024;
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, uint inputSize, byte[] output, uint outputSize, out uint returned, IntPtr overlapped);

    static SafeFileHandle Open(string name, bool write) {
        SafeFileHandle handle = CreateFile(name, GENERIC_READ | (write ? GENERIC_WRITE : 0), SHARE, IntPtr.Zero, OPEN_EXISTING, write ? 0x80000000U : 0U, IntPtr.Zero);
        if (handle.IsInvalid) { int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Windows could not open the selected device."); }
        return handle;
    }
    static FileStream Disk(int number, bool write) { return new FileStream(Open(@"\\.\PhysicalDrive" + number, write), write ? FileAccess.ReadWrite : FileAccess.Read, CHUNK, false); }
    static SafeFileHandle Lock(string volume) {
        SafeFileHandle handle = Open(volume.TrimEnd('\\'), true);
        uint returned;
        if (!DeviceIoControl(handle, FSCTL_LOCK_VOLUME, null, 0, null, 0, out returned, IntPtr.Zero)) {
            int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "The volume is in use. Close its files and applications, then try again.");
        }
        if (!DeviceIoControl(handle, FSCTL_DISMOUNT_VOLUME, null, 0, null, 0, out returned, IntPtr.Zero)) {
            int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error, "Windows could not dismount the locked volume.");
        }
        return handle;
    }
    static void ReadExact(Stream stream, byte[] bytes, int count) {
        int got = 0;
        while (got < count) { int read = stream.Read(bytes, got, count - got); if (read <= 0) throw new EndOfStreamException("The device ended before the requested range."); got += read; }
    }
    static bool Cancelled(string file) { return !String.IsNullOrEmpty(file) && File.Exists(file); }
    static string Hash(Stream source, long offset, long length, string cancellation = null, Action<long,long,string,bool> progress = null, string phase = "Verifying partition data") {
        source.Position = offset;
        using (SHA256 sha = SHA256.Create()) {
            byte[] bytes = new byte[CHUNK]; long read = 0; DateTime emitted = DateTime.MinValue;
            while (read < length) {
                if (Cancelled(cancellation)) throw new OperationCanceledException("Cancelled during verification.");
                int count = (int)Math.Min(bytes.Length, length - read); ReadExact(source, bytes, count); sha.TransformBlock(bytes, 0, count, null, 0); read += count;
                if (progress != null && (read == length || (DateTime.UtcNow - emitted).TotalMilliseconds >= 200)) { progress(read, length, phase, !String.IsNullOrEmpty(cancellation)); emitted = DateTime.UtcNow; }
            }
            sha.TransformFinalBlock(new byte[0], 0, 0); return BitConverter.ToString(sha.Hash).Replace("-", "");
        }
    }
    static void CopyRange(Stream source, long sourceOffset, Stream destination, long destinationOffset, long length, string cancellation, bool cancellable, string phase, Action<long,long,string,bool> progress) {
        source.Position = sourceOffset; destination.Position = destinationOffset;
        byte[] bytes = new byte[CHUNK]; long complete = 0; DateTime emitted = DateTime.MinValue;
        while (complete < length) {
            if (cancellable && Cancelled(cancellation)) throw new OperationCanceledException("Cancelled before the next write phase.");
            int count = (int)Math.Min(bytes.Length, length - complete);
            ReadExact(source, bytes, count); destination.Write(bytes, 0, count); complete += count;
            if (progress != null && (complete == length || (DateTime.UtcNow - emitted).TotalMilliseconds >= 200)) { progress(complete, length, phase, cancellable); emitted = DateTime.UtcNow; }
        }
    }
    static void Journal(string file, string state) {
        if (String.IsNullOrEmpty(file)) return;
        using (FileStream stream = new FileStream(file + ".state", FileMode.Append, FileAccess.Write, FileShare.Read)) {
            byte[] bytes = Encoding.UTF8.GetBytes(DateTime.UtcNow.ToString("o") + " " + state + Environment.NewLine); stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
        }
    }
    static byte[] Layout(SafeFileHandle handle) {
        for (int size = 16384; size <= 1048576; size *= 2) {
            byte[] bytes = new byte[size]; uint returned;
            if (DeviceIoControl(handle, GET_LAYOUT, null, 0, bytes, (uint)bytes.Length, out returned, IntPtr.Zero)) {
                if (returned < 48) throw new IOException("Windows returned an incomplete partition layout.");
                Array.Resize(ref bytes, (int)returned); return bytes;
            }
            int error = Marshal.GetLastWin32Error(); if (error != 122 && error != 234 && error != 24) throw new Win32Exception(error, "Could not read the disk partition layout.");
        }
        throw new IOException("The partition layout exceeds the supported size.");
    }
    static void SetLayout(SafeFileHandle handle, byte[] bytes) {
        uint returned;
        if (!DeviceIoControl(handle, SET_LAYOUT, bytes, (uint)bytes.Length, null, 0, out returned, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows rejected the new partition layout.");
    }
    static void Update(SafeFileHandle handle) {
        uint returned;
        if (!DeviceIoControl(handle, UPDATE_PROPERTIES, null, 0, null, 0, out returned, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not refresh the partition layout.");
    }
    static byte[] MoveLayout(byte[] original, int number, long oldOffset, long size, long newOffset, int sector) {
        byte[] bytes = (byte[])original.Clone(); int style = BitConverter.ToInt32(bytes, 0), count = BitConverter.ToInt32(bytes, 4), found = 0;
        // Windows DRIVE_LAYOUT_INFORMATION_EX has a 48-byte header and 144-byte PARTITION_INFORMATION_EX entries on x64.
        if ((style != 0 && style != 1) || count < 1 || count > 4096 || bytes.Length < 48L + 144L * count) throw new IOException("Unsupported or inconsistent partition layout.");
        for (int index = 0; index < count; index++) {
            int entry = 48 + index * 144;
            long otherOffset = BitConverter.ToInt64(bytes, entry + 8), otherSize = BitConverter.ToInt64(bytes, entry + 16);
            bool isSource = BitConverter.ToUInt32(bytes, entry + 24) == number && otherOffset == oldOffset;
            if (!isSource && otherSize > 0 && newOffset < otherOffset + otherSize && newOffset + size > otherOffset) throw new IOException("The native destination overlaps another partition.");
            if (BitConverter.ToUInt32(bytes, entry + 24) != number || BitConverter.ToInt64(bytes, entry + 8) != oldOffset) continue;
            if (BitConverter.ToInt64(bytes, entry + 16) != size || BitConverter.ToInt32(bytes, entry) != style) throw new IOException("The source partition geometry changed.");
            Buffer.BlockCopy(BitConverter.GetBytes(newOffset), 0, bytes, entry + 8, 8); bytes[entry + 28] = 1;
            if (style == 0) {
                if (bytes[entry + 32] == 5 || bytes[entry + 32] == 15 || bytes[entry + 32] == 0x85 || bytes[entry + 33] != 0) throw new IOException("Extended and active MBR partitions cannot be moved.");
                if (newOffset / sector > UInt32.MaxValue) throw new IOException("The new MBR offset exceeds 32-bit addressing.");
                Buffer.BlockCopy(BitConverter.GetBytes((uint)(newOffset / sector)), 0, bytes, entry + 36, 4);
            }
            found++;
        }
        if (found != 1) throw new IOException("The exact source partition was not found in the native layout.");
        return bytes;
    }
    public static byte[] ProjectMoveLayout(byte[] original, int number, long oldOffset, long size, long newOffset, int sector) { return MoveLayout(original, number, oldOffset, size, newOffset, sector); }
    static byte[] RandomSerial(int count) { byte[] serial = new byte[count]; using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) rng.GetBytes(serial); return serial; }
    public static uint ExFatChecksum(byte[] region, int sectorSize) {
        if (region.Length < sectorSize * 11) throw new ArgumentException("Incomplete exFAT boot region.");
        uint checksum = 0;
        for (int index = 0; index < sectorSize * 11; index++) { if (index == 106 || index == 107 || index == 112) continue; unchecked { checksum = ((checksum & 1) != 0 ? 0x80000000U : 0U) + (checksum >> 1) + region[index]; } }
        return checksum;
    }
    // Pure boot-record fixups are public so fixtures can validate them without opening a physical device.
    public static byte[] PatchBootRegion(byte[] original, string filesystem, long newOffset, int sectorSize, byte[] serial) {
        byte[] bytes = (byte[])original.Clone();
        if (bytes.Length < sectorSize || bytes[510] != 0x55 || bytes[511] != 0xaa || newOffset % sectorSize != 0) throw new IOException("The volume boot sector is invalid or unsupported.");
        string oem = Encoding.ASCII.GetString(bytes, 3, 8);
        if (filesystem.Equals("exFAT", StringComparison.OrdinalIgnoreCase)) {
            if (oem != "EXFAT   " || bytes.Length < 24 * sectorSize || (1 << bytes[108]) != sectorSize) throw new IOException("The exFAT boot region is inconsistent.");
            for (int copy = 0; copy < 2; copy++) {
                int begin = copy * sectorSize * 12;
                Buffer.BlockCopy(BitConverter.GetBytes((ulong)(newOffset / sectorSize)), 0, bytes, begin + 64, 8);
                if (serial != null) Buffer.BlockCopy(serial, 0, bytes, begin + 100, 4);
                byte[] region = new byte[11 * sectorSize]; Buffer.BlockCopy(bytes, begin, region, 0, region.Length);
                byte[] checksum = BitConverter.GetBytes(ExFatChecksum(region, sectorSize));
                for (int offset = begin + 11 * sectorSize; offset < begin + 12 * sectorSize; offset += 4) Buffer.BlockCopy(checksum, 0, bytes, offset, 4);
            }
        } else {
            if (BitConverter.ToUInt16(bytes, 11) != sectorSize || newOffset / sectorSize > UInt32.MaxValue) throw new IOException("The boot record cannot represent the requested offset.");
            Buffer.BlockCopy(BitConverter.GetBytes((uint)(newOffset / sectorSize)), 0, bytes, 28, 4);
            if (filesystem == "NTFS") {
                if (oem != "NTFS    ") throw new IOException("The NTFS boot record is inconsistent.");
                if (serial != null) Buffer.BlockCopy(serial, 0, bytes, 72, 8);
            } else if (filesystem == "FAT32") {
                if (serial != null) Buffer.BlockCopy(serial, 0, bytes, 67, 4);
                int backup = BitConverter.ToUInt16(bytes, 50);
                if (backup > 0 && backup != 65535 && (backup + 1) * sectorSize <= bytes.Length) {
                    Buffer.BlockCopy(BitConverter.GetBytes((uint)(newOffset / sectorSize)), 0, bytes, backup * sectorSize + 28, 4);
                    if (serial != null) Buffer.BlockCopy(serial, 0, bytes, backup * sectorSize + 67, 4);
                }
            } else if (filesystem == "FAT") { if (serial != null) Buffer.BlockCopy(serial, 0, bytes, 39, 4); }
            else throw new IOException("The file system does not support native relocation.");
        }
        return bytes;
    }
    static void PatchBoot(FileStream disk, long offset, long size, string filesystem, int sectorSize, bool newSerial) {
        int regionSize = (int)Math.Min(size, 24L * sectorSize);
        byte[] original = new byte[regionSize]; disk.Position = offset; ReadExact(disk, original, original.Length);
        byte[] serial = newSerial ? RandomSerial(filesystem == "NTFS" ? 8 : 4) : null;
        byte[] patched = PatchBootRegion(original, filesystem, offset, sectorSize, serial);
        disk.Position = offset; disk.Write(patched, 0, patched.Length);
        byte[] expectedBackup = null; long backupLocation = 0;
        if (filesystem == "NTFS") {
            long backup = offset + size - sectorSize;
            byte[] backupBytes = new byte[sectorSize]; disk.Position = backup; ReadExact(disk, backupBytes, backupBytes.Length);
            if (Encoding.ASCII.GetString(backupBytes, 3, 8) != "NTFS    ") throw new IOException("The NTFS backup boot sector is invalid.");
            byte[] patchedBackup = PatchBootRegion(backupBytes, filesystem, offset, sectorSize, serial);
            disk.Position = backup; disk.Write(patchedBackup, 0, patchedBackup.Length);
            expectedBackup = patchedBackup; backupLocation = backup;
        }
        disk.Flush(true);
        byte[] verified = new byte[patched.Length]; disk.Position = offset; ReadExact(disk, verified, verified.Length);
        if (!Equal(verified, patched)) throw new IOException("The updated boot records could not be verified.");
        if (expectedBackup != null) { byte[] verifiedBackup = new byte[expectedBackup.Length]; disk.Position = backupLocation; ReadExact(disk, verifiedBackup, verifiedBackup.Length); if (!Equal(verifiedBackup, expectedBackup)) throw new IOException("The updated NTFS backup boot record could not be verified."); }
    }
    static bool Equal(byte[] one, byte[] two) { if (one.Length != two.Length) return false; int difference = 0; for (int index = 0; index < one.Length; index++) difference |= one[index] ^ two[index]; return difference == 0; }
    public static byte[] Read(int diskNumber, long offset, int count) {
        using (FileStream disk = Disk(diskNumber, false)) { byte[] bytes = new byte[count]; disk.Position = offset; ReadExact(disk, bytes, count); return bytes; }
    }
    public static void StageVolume(int diskNumber, string volume, long offset, long length, string imageFile, string cancellation, Action<long,long,string,bool> progress) {
        using (SafeFileHandle locked = Lock(volume)) using (FileStream source = Disk(diskNumber, false)) {
            byte[] layout = Layout(source.SafeFileHandle);
            using (FileStream saved = new FileStream(imageFile + ".layout", FileMode.CreateNew, FileAccess.Write, FileShare.Read)) { saved.Write(layout, 0, layout.Length); saved.Flush(true); }
            using (FileStream image = new FileStream(imageFile, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read, CHUNK, FileOptions.WriteThrough)) {
                CopyRange(source, offset, image, 0, length, cancellation, true, "Backing up the complete original file system", progress); image.Flush(true);
                if (Hash(source, offset, length, cancellation, progress, "Verifying the original file system") != Hash(image, 0, length, cancellation, progress, "Verifying the recovery image")) throw new IOException("The complete recovery image did not verify. No conversion was started.");
            }
        }
    }
    public static void RestoreStagedVolume(int diskNumber, string volume, long offset, long length, string imageFile, Action<long,long,string,bool> progress) {
        byte[] originalLayout = File.ReadAllBytes(imageFile + ".layout");
        using (SafeFileHandle locked = Lock(volume)) using (FileStream destination = Disk(diskNumber, true)) using (FileStream image = new FileStream(imageFile, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            if (image.Length != length) throw new IOException("The recovery image capacity changed.");
            byte[] currentLayout = Layout(destination.SafeFileHandle);
            if (currentLayout.Length != originalLayout.Length || BitConverter.ToInt32(currentLayout,0) != BitConverter.ToInt32(originalLayout,0) || BitConverter.ToInt32(currentLayout,4) != BitConverter.ToInt32(originalLayout,4)) throw new IOException("The disk layout changed; automatic restore was stopped to protect other partitions.");
            for(int header=0;header<48;header++)if(currentLayout[header]!=originalLayout[header])throw new IOException("The disk layout identity changed; automatic restore was stopped.");
            int count = BitConverter.ToInt32(originalLayout,4), matched = 0;
            for (int index=0;index<count;index++) {
                int entry=48+index*144;
                bool target=BitConverter.ToInt64(originalLayout,entry+8)==offset && BitConverter.ToInt64(originalLayout,entry+16)==length;
                if (target) {
                    if (BitConverter.ToInt64(currentLayout,entry+8)!=offset || BitConverter.ToInt64(currentLayout,entry+16)!=length) throw new IOException("The restore target moved or resized.");
                    matched++;
                } else {
                    for (int part=0;part<144;part++) if (part!=28 && originalLayout[entry+part]!=currentLayout[entry+part]) throw new IOException("Another partition changed; automatic restore was stopped.");
                }
            }
            if (matched!=1) throw new IOException("The recovery target was not found exactly once.");
            CopyRange(image,0,destination,offset,length,null,false,"Restoring the original file system from the verified recovery image",progress); destination.Flush(true);
            if (Hash(image,0,length)!=Hash(destination,offset,length)) throw new IOException("The recovery image restore did not verify.");
            SetLayout(destination.SafeFileHandle,originalLayout);Update(destination.SafeFileHandle);
        }
    }
    public static PartlyScanResult Scan(int diskNumber, long offset, long length, int sectorSize, string cancellation, Action<long,long,string,bool> progress) {
        PartlyScanResult result = new PartlyScanResult(); result.TotalBytes = length;
        using (FileStream disk = Disk(diskNumber, false)) {
            byte[] bytes = new byte[CHUNK]; DateTime emitted = DateTime.MinValue;
            for (long complete = 0; complete < length;) {
                if (Cancelled(cancellation)) { result.Cancelled = true; break; }
                int count = (int)Math.Min(bytes.Length, length - complete);
                try { disk.Position = offset + complete; ReadExact(disk, bytes, count); }
                catch (IOException) {
                    for (int part = 0; part < count; part += sectorSize) {
                        if (Cancelled(cancellation)) { result.Cancelled = true; break; }
                        try { disk.Position = offset + complete + part; ReadExact(disk, bytes, Math.Min(sectorSize, count - part)); }
                        catch (IOException error) { result.BadSectors++; if (result.Errors.Count < 1000) result.Errors.Add(new PartlyScanError { Sector = (offset + complete + part) / sectorSize, ErrorCode = error.HResult, Message = error.Message }); }
                    }
                }
                if (result.Cancelled) break;
                complete += count; result.ScannedBytes = complete;
                if (progress != null && (complete == length || (DateTime.UtcNow - emitted).TotalMilliseconds >= 200)) { progress(complete, length, "Reading disk surface", true); emitted = DateTime.UtcNow; }
            }
        }
        return result;
    }
    public static void WriteSectors(int diskNumber, string volume, long offset, byte[] original, byte[] replacement, string backupFile) {
        using (SafeFileHandle locked = Lock(volume)) using (FileStream disk = Disk(diskNumber, true)) {
            byte[] current = new byte[original.Length]; disk.Position = offset; ReadExact(disk, current, current.Length);
            if (!Equal(current, original)) throw new IOException("Sector contents changed after they were opened. Refresh the sector viewer before editing.");
            using (FileStream backup = new FileStream(backupFile, FileMode.CreateNew, FileAccess.Write, FileShare.Read)) { backup.Write(original, 0, original.Length); backup.Flush(true); }
            try {
                disk.Position = offset; disk.Write(replacement, 0, replacement.Length); disk.Flush(true);
                byte[] verify = new byte[replacement.Length]; disk.Position = offset; ReadExact(disk, verify, verify.Length);
                if (!Equal(replacement, verify)) throw new IOException("The written sector bytes did not verify.");
            } catch (Exception operationError) {
                try {
                    disk.Position = offset; disk.Write(original, 0, original.Length); disk.Flush(true);
                    byte[] restored = new byte[original.Length]; disk.Position = offset; ReadExact(disk, restored, restored.Length);
                    if (!Equal(original, restored)) throw new IOException("The original sector restore did not verify.");
                } catch (Exception restoreError) { throw new IOException("The sector write failed and automatic restore could not finish. Preserve the sector backup at " + backupFile + ". " + restoreError.Message, operationError); }
                throw;
            }
        }
    }
    public static void Move(int diskNumber, string volume, int partitionNumber, long oldOffset, long size, long newOffset, int sectorSize, string filesystem, string imageFile, string journalFile, string cancellation, Action<long,long,string,bool> progress) {
        using (SafeFileHandle locked = Lock(volume)) using (FileStream disk = Disk(diskNumber, true)) {
            byte[] originalLayout = Layout(disk.SafeFileHandle), movedLayout = MoveLayout(originalLayout, partitionNumber, oldOffset, size, newOffset, sectorSize);
            using (FileStream layoutFile = new FileStream(imageFile + ".layout", FileMode.CreateNew, FileAccess.Write, FileShare.Read)) { layoutFile.Write(originalLayout, 0, originalLayout.Length); layoutFile.Flush(true); }
            Journal(journalFile, "staging-source");
            using (FileStream image = new FileStream(imageFile, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read, CHUNK, FileOptions.WriteThrough)) {
                CopyRange(disk, oldOffset, image, 0, size, cancellation, true, "Backing up the entire source partition", progress); image.Flush(true);
                string imageHash = Hash(image, 0, size, cancellation, progress, "Verifying the staging image"), sourceHash = Hash(disk, oldOffset, size, cancellation, progress, "Verifying the source against its backup");
                if (!String.Equals(imageHash, sourceHash, StringComparison.Ordinal)) throw new IOException("The source staging image failed verification. No disk bytes were changed.");
                Journal(journalFile, "staging-verified sha256=" + imageHash);
                if (Cancelled(cancellation)) throw new OperationCanceledException("Cancelled before writing to the disk.");
                if (!Equal(Layout(disk.SafeFileHandle), originalLayout)) throw new IOException("The disk layout changed while its backup was being created. No relocation bytes were written.");
                bool destinationStarted = false;
                try {
                    Journal(journalFile, "destination-writing cancellation-deferred"); destinationStarted = true;
                    CopyRange(image, 0, disk, newOffset, size, null, false, "Moving partition data — cancellation deferred", progress); disk.Flush(true);
                    if (!String.Equals(Hash(disk, newOffset, size, null, progress, "Verifying the relocated partition — cancellation deferred"), imageHash, StringComparison.Ordinal)) throw new IOException("The destination copy failed verification.");
                    PatchBoot(disk, newOffset, size, filesystem, sectorSize, false);
                    if (!Equal(Layout(disk.SafeFileHandle), originalLayout)) throw new IOException("The disk layout changed during relocation. Restoring the original partition.");
                    Journal(journalFile, "destination-verified committing-layout");
                    SetLayout(disk.SafeFileHandle, movedLayout); Update(disk.SafeFileHandle);
                    byte[] actual = Layout(disk.SafeFileHandle); MoveLayout(actual, partitionNumber, newOffset, size, oldOffset, sectorSize);
                    Journal(journalFile, "completed");
                } catch (Exception operationError) {
                    Journal(journalFile, "failed rollback-starting");
                    try {
                        if (destinationStarted && newOffset < oldOffset + size && newOffset + size > oldOffset) { CopyRange(image, 0, disk, oldOffset, size, null, false, "Restoring the original partition from its backup", progress); disk.Flush(true); if (Hash(disk, oldOffset, size) != imageHash) throw new IOException("Source restore verification failed."); }
                        SetLayout(disk.SafeFileHandle, originalLayout); Update(disk.SafeFileHandle); Journal(journalFile, "rolled-back");
                    } catch (Exception restoreError) { Journal(journalFile, "recovery-required " + restoreError.Message); throw new IOException("The move failed and automatic rollback could not finish. Preserve the staging image and recovery journal. " + restoreError.Message, operationError); }
                    throw;
                }
            }
        }
    }
    public static void Clone(int sourceDisk, string sourceVolume, long sourceOffset, int destinationDisk, string destinationVolume, long destinationOffset, long length, int sectorSize, string filesystem, string cancellation, Action<long,long,string,bool> progress) {
        using (SafeFileHandle locked = Lock(sourceVolume)) using (SafeFileHandle destinationLock = Lock(destinationVolume)) using (FileStream source = Disk(sourceDisk, false)) using (FileStream destination = Disk(destinationDisk, true)) {
            // The source remains untouched and locked; cancellation only leaves a partially copied new destination partition.
            CopyRange(source, sourceOffset, destination, destinationOffset, length, cancellation, true, "Copying the locked source volume", progress); destination.Flush(true);
            if (progress != null) progress(0, length, "Verifying the volume copy", true);
            if (Hash(source, sourceOffset, length, cancellation, progress, "Verifying the source volume") != Hash(destination, destinationOffset, length, cancellation, progress, "Verifying the copied volume")) throw new IOException("The volume copy failed verification.");
            if (Cancelled(cancellation)) throw new OperationCanceledException("The copy was cancelled before mounting its destination.");
            PatchBoot(destination, destinationOffset, length, filesystem, sectorSize, true); Update(destination.SafeFileHandle);
        }
    }
}
'@

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-Letter($Value) { return ([string]$Value).Trim([char]0).Trim().ToUpperInvariant() }
function Assert-Integer($Value, $Name, [long]$Minimum = 0, [long]$Maximum = 9007199254740991) {
    if ($null -eq $Value -or [string]$Value -notmatch '^\d+$') { throw "$Name must be a non-negative integer." }
    $number = [long]$Value
    if ($number -lt $Minimum -or $number -gt $Maximum) { throw "$Name is outside the supported range." }
    return $number
}
function Get-Target($Target, [bool]$PartitionRequired = $false, [bool]$Write = $false) {
    $number = Assert-Integer $Target.diskNumber 'Disk number'
    if ([string]::IsNullOrWhiteSpace([string]$Target.diskUniqueId)) { throw 'Disk identity is missing.' }
    $disk = Get-Disk -Number $number -ErrorAction Stop
    if ([string]$disk.UniqueId -cne [string]$Target.diskUniqueId) { throw 'The disk identity changed. Refresh the disk list.' }
    if ($disk.IsOffline) { throw 'This disk is offline.' }
    $partition = $null; $volume = $null
    if ($PartitionRequired -or $null -ne $Target.partitionNumber) {
        $partitionNumber = Assert-Integer $Target.partitionNumber 'Partition number' 1
        $partition = Get-Partition -DiskNumber $number -PartitionNumber $partitionNumber -ErrorAction Stop
        $offset = Assert-Integer $Target.partitionOffset 'Partition offset'
        if ([long]$partition.Offset -ne $offset) { throw 'The partition moved or changed. Refresh the disk list.' }
        try { $volume = @($partition | Get-Volume -ErrorAction Stop)[0] } catch { }
    }
    if ($Write) {
        if ($disk.IsReadOnly -or [string]$disk.HealthStatus -ne 'Healthy' -or [string]$disk.BusType -eq 'Spaces' -or $disk.IsClustered) { throw 'This disk is read-only, unhealthy, clustered, or managed by Storage Spaces.' }
        if ([string]$disk.PartitionStyle -notin @('GPT', 'MBR')) { throw 'Initialize the disk first.' }
        if ($partition) {
            $gpt = ([string]$partition.GptType).Trim('{}').ToLowerInvariant()
            $letter = Get-Letter $partition.DriveLetter
            if ($partition.IsBoot -or $partition.IsSystem -or $partition.IsReadOnly -or ($letter -and ($letter + ':') -eq $env:SystemDrive) -or ($gpt -and $gpt -ne 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7') -or [string]$partition.Type -match 'System|Reserved|Recovery|Extended|Unknown') { throw 'Windows boot, system, recovery, reserved, and read-only partitions are protected.' }
            if ($null -eq $volume -or [string]$volume.FileSystemType -notin @('NTFS', 'FAT', 'FAT32', 'exFAT')) { throw 'Select an accessible NTFS, FAT, FAT32, or exFAT data volume.' }
            Assert-Unencrypted $partition $volume
        }
    }
    $sector = [int]$disk.LogicalSectorSize
    if ($sector -notin @(512, 1024, 2048, 4096)) { throw 'Unsupported logical sector size.' }
    return @{ disk = $disk; partition = $partition; volume = $volume; sectorSize = $sector }
}
function Assert-Unencrypted($Partition, $Volume) {
    try {
        $items = @(Get-CimInstance -Namespace 'Root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop)
        $path = ([string]$Volume.Path).TrimEnd('\')
        $letter = Get-Letter $Partition.DriveLetter
        $matches = @($items | Where-Object { ([string]$_.DeviceID).TrimEnd('\') -eq $path -or ($letter -and [string]$_.DriveLetter -eq ($letter + ':')) })
        if ($matches.Count) {
            $lock = Invoke-CimMethod -InputObject $matches[0] -MethodName GetLockStatus -ErrorAction Stop
            $status = Invoke-CimMethod -InputObject $matches[0] -MethodName GetConversionStatus -ErrorAction Stop
            if ($lock.ReturnValue -ne 0 -or $status.ReturnValue -ne 0 -or $lock.LockStatus -ne 0 -or $status.ConversionStatus -ne 0) { throw 'The data volume is encrypted or locked.' }
        }
    } catch { throw 'Windows could not verify that this volume is unlocked and fully decrypted. No advanced disk write was started.' }
}
function Assert-Snapshot($Request, [int[]]$Numbers) {
    if ($null -eq $Request.expectedSnapshot.disks) { throw 'The original disk snapshot is required.' }
    foreach ($number in @($Numbers | Sort-Object -Unique)) {
        $before = @($Request.expectedSnapshot.disks | Where-Object { [int]$_.number -eq $number })
        if ($before.Count -ne 1) { throw "Disk $number is missing from the original snapshot." }
        $disk = Get-Disk -Number $number -ErrorAction Stop
        if ([string]$before[0].uniqueId -cne [string]$disk.UniqueId -or [long]$before[0].size -ne [long]$disk.Size -or [string]$before[0].partitionStyle -ne [string]$disk.PartitionStyle) { throw "Disk $number changed since the operation was prepared." }
        $actual = @(Get-Partition -DiskNumber $number -ErrorAction Stop)
        $expected = @($before[0].partitions)
        if ($actual.Count -ne $expected.Count) { throw "Partitions on disk $number changed. Refresh the disk list." }
        foreach ($partition in $actual) {
            $old = @($expected | Where-Object { [int]$_.partitionNumber -eq [int]$partition.PartitionNumber })
            if ($old.Count -ne 1 -or [long]$old[0].offset -ne [long]$partition.Offset -or [long]$old[0].size -ne [long]$partition.Size -or (Get-Letter $old[0].driveLetter) -cne (Get-Letter $partition.DriveLetter)) { throw "The layout of disk $number changed. Refresh before applying changes." }
        }
    }
}
function Assert-LocalBackupFolder([string]$Folder, [int]$ExcludedDisk, [long]$BytesRequired) {
    if (-not [IO.Path]::IsPathRooted($Folder) -or $Folder.StartsWith('\\') -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { throw 'Choose an existing local backup folder.' }
    $resolved = (Resolve-Path -LiteralPath $Folder -ErrorAction Stop).ProviderPath
    if ($resolved.StartsWith('\\')) { throw 'A local backup folder is required.' }
    $volume = Get-Volume -FilePath $resolved -ErrorAction Stop
    $partitions = @($volume | Get-Partition -ErrorAction Stop)
    if ($partitions.Count -ne 1 -or [int]$partitions[0].DiskNumber -eq $ExcludedDisk) { throw 'The backup folder must be on another physical disk.' }
    if ([long]$volume.SizeRemaining -lt $BytesRequired + 16MB) { throw 'The backup volume does not have enough free space.' }
    if ([string]$volume.FileSystemType -notin @('NTFS', 'exFAT')) { throw 'Use an NTFS or exFAT backup folder for reliable large images.' }
    return $resolved
}
function New-RecoveryJournal($Request, $Information) {
    $root = [string]$Request.recoveryRoot
    if (-not [IO.Path]::IsPathRooted($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { throw 'The local recovery journal folder is unavailable.' }
    $id = [guid]::NewGuid().ToString()
    $path = Join-Path $root ($id + '.json')
    $journal = [ordered]@{ id = $id; action = $Action; createdAt = [DateTime]::UtcNow.ToString('o'); target = $Request.target; params = $Request.params; information = $Information; statusLog = $path + '.state' }
    $json = $journal | ConvertTo-Json -Depth 12
    $stream = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes($json); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $script:RecoveryPath = $path
    return $path
}

function Get-ConversionManifest([string]$Root,[bool]$RejectStreams=$false) {
    $files=New-Object 'System.Collections.Generic.List[object]'
    $directories=New-Object 'System.Collections.Generic.List[string]'
    $pending=New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root.TrimEnd('\')+'\')
    while($pending.Count){
        if($CancellationFile -and (Test-Path -LiteralPath $CancellationFile)){throw (New-Object OperationCanceledException('Conversion cancelled before formatting.'))}
        $directory=$pending.Pop()
        foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)){
            $relative=$entry.Substring($Root.TrimEnd('\').Length).TrimStart('\')
            if($relative -in @('System Volume Information','$RECYCLE.BIN')){continue}
            $attributes=[IO.File]::GetAttributes($entry)
            if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('Conversion cannot preserve this reparse point: '+$relative+'. Move it out of the volume or use a file system that supports its semantics.')}
            if(($attributes -band [IO.FileAttributes]::Encrypted) -ne 0){throw ('Decrypt the EFS-encrypted file before conversion: '+$relative)}
            if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){$directories.Add($relative);$pending.Push($entry);continue}
            if($RejectStreams){$streams=@(Get-Item -LiteralPath $entry -Stream '*' -ErrorAction Stop|Where-Object {$_.Stream -ne ':$DATA'});if($streams.Count){throw ('The target file system cannot preserve alternate data streams in '+$relative+'. No formatting was started.')}}
            $info=New-Object IO.FileInfo($entry)
            $hash=(Get-FileHash -LiteralPath $entry -Algorithm SHA256 -ErrorAction Stop).Hash
            $files.Add(@{relative=$relative;size=[long]$info.Length;writeTicks=[long]$info.LastWriteTimeUtc.Ticks;hash=$hash})
        }
    }
    return @{files=@($files.ToArray()|Sort-Object relative);directories=@($directories.ToArray()|Sort-Object)}
}
function Assert-ConversionManifest($Expected,$Actual,[bool]$CompareTimes=$true) {
    if(@($Expected.files).Count -ne @($Actual.files).Count -or (@($Expected.directories)-join "`n") -cne (@($Actual.directories)-join "`n")){throw 'The file or folder list changed. Conversion stopped before further changes.'}
    for($index=0;$index -lt @($Expected.files).Count;$index++){
        $before=$Expected.files[$index];$after=$Actual.files[$index]
        if($before.relative -cne $after.relative -or $before.size -ne $after.size -or $before.hash -cne $after.hash -or ($CompareTimes -and $before.writeTicks -ne $after.writeTicks)){throw ('File verification failed: '+$before.relative)}
    }
}
function Copy-ConversionFiles([string]$Source,[string]$Destination,[bool]$PreserveAcl) {
    $copy=if($PreserveAcl){'/COPYALL'}else{'/COPY:DAT'}
    $sourcePath=$Source.TrimEnd('\');$destinationPath=$Destination.TrimEnd('\')
    if($sourcePath -match '^[A-Za-z]:$'){$sourcePath+='\'}
    if($destinationPath -match '^[A-Za-z]:$'){$destinationPath+='\'}
    $arguments=@($sourcePath,$destinationPath,'/E',$copy,'/DCOPY:DAT','/XJ','/R:1','/W:1','/NP','/NJH','/NJS','/XD','System Volume Information','$RECYCLE.BIN')
    $output=& "$env:SystemRoot\System32\robocopy.exe" @arguments 2>&1
    if($LASTEXITCODE -ge 8){throw ('File staging or restore failed: '+($output -join "`n"))}
}
function Invoke-StagedConversion($Request,$Target,$Progress) {
    $disk=$Target.disk;$partition=$Target.partition;$volume=$Target.volume
    $fileSystem=[string]$Request.params.fileSystem
    if($fileSystem -cnotin @('NTFS','FAT32','exFAT') -or $fileSystem -eq [string]$volume.FileSystemType){throw 'Choose a different NTFS, FAT32, or exFAT target file system.'}
    if($fileSystem -eq 'FAT32' -and [long]$partition.Size -gt 34359738368){throw 'Windows FAT32 formatting supports up to 32 GiB. Resize the volume first or choose exFAT.'}
    if([string]$volume.FileSystemType -eq 'NTFS' -and $fileSystem -ne 'NTFS' -and $Request.params.allowMetadataChanges -ne $true){throw 'Confirm that the target file system cannot retain NTFS permissions, compression, and other NTFS-only metadata.'}
    $letter=Get-Letter $partition.DriveLetter
    if(-not $letter){throw 'Assign a drive letter before converting this file system.'}
    $root=$letter+':\'
    $maximum=if($fileSystem -eq 'FAT32'){11}elseif($fileSystem -eq 'exFAT'){15}else{32}
    $label=[string]$Request.params.label
    if($label.Length -gt $maximum -or $label -match '[\\/:*?"<>|\x00-\x1f]'){throw 'The new volume label is invalid for the target file system.'}
    $Progress.Invoke(0,100,'Checking all source files and target file-system limits',$true)
    $before=Get-ConversionManifest $root ([string]$volume.FileSystemType -eq 'NTFS' -and $fileSystem -ne 'NTFS')
    $total=0L
    foreach($file in @($before.files)){$total+=[long]$file.size;if($fileSystem -eq 'FAT32' -and [long]$file.size -gt 4294967295){throw ('FAT32 cannot preserve a file larger than 4 GiB: '+$file.relative)}}
    if($total -gt [long]$partition.Size*0.95){throw 'Leave at least five percent free capacity before staged conversion to accommodate target file-system metadata.'}
    $folder=Assert-LocalBackupFolder $Request.params.stagingDirectory ([int]$disk.Number) ([long]$partition.Size+$total)
    $backupVolume=Get-Volume -FilePath $folder -ErrorAction Stop
    if([string]$backupVolume.FileSystemType -ne 'NTFS'){throw 'Use an NTFS staging volume so the original file metadata can be backed up.'}
    $work=Join-Path $folder ('Partly20-convert-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work|Out-Null
    $files=Join-Path $work 'files';New-Item -ItemType Directory -Path $files|Out-Null
    $image=Join-Path $work 'original-partition.img'
    $journal=New-RecoveryJournal $Request @{imageFile=$image;stagingDirectory=$work;sourceFileSystem=[string]$volume.FileSystemType;targetFileSystem=$fileSystem;originalOffset=[long]$partition.Offset;size=[long]$partition.Size}
    Assert-Snapshot $Request @([int]$disk.Number)
    [PartlyDiskIo]::StageVolume([int]$disk.Number,[string]$volume.Path,[long]$partition.Offset,[long]$partition.Size,$image,$CancellationFile,$Progress)
    $Progress.Invoke(20,100,'Staging all files before file-system conversion',$true)
    Copy-ConversionFiles $root $files $false
    $staged=Get-ConversionManifest ($files+'\')
    Assert-ConversionManifest $before $staged $false
    $live=Get-ConversionManifest $root ([string]$volume.FileSystemType -eq 'NTFS' -and $fileSystem -ne 'NTFS')
    Assert-ConversionManifest $before $live $true
    $before|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $work 'file-manifest.json') -Encoding UTF8
    Assert-Snapshot $Request @([int]$disk.Number)
    if($CancellationFile -and (Test-Path -LiteralPath $CancellationFile)){throw (New-Object OperationCanceledException('Conversion cancelled before formatting. The verified recovery image was retained.'))}
    $formatStarted=$false
    try{
        $Progress.Invoke(40,100,'Creating the target file system; cancellation is deferred through restore and verification',$false)
        $formatStarted=$true
        $partition|Format-Volume -FileSystem $fileSystem -NewFileSystemLabel $label -Confirm:$false -ErrorAction Stop|Out-Null
        $Progress.Invoke(55,100,'Restoring files to the new file system',$false)
        Copy-ConversionFiles $files $root $false
        # Ignore a cancellation request until the files have been restored and verified.
        $savedCancellation=$CancellationFile;$CancellationFile=$null
        try{$restored=Get-ConversionManifest $root;Assert-ConversionManifest $before $restored $false}finally{$CancellationFile=$savedCancellation}
        $Progress.Invoke(100,100,'File-system conversion completed and every file verified',$true)
        return @{success=$true;message='The file system was converted and all file contents verified. The complete original image and staging files were retained.';fileSystem=$fileSystem;verifiedFiles=@($before.files).Count;imageFile=$image;recoveryJournal=$journal;stagingDirectory=$work;requiresRefresh=$true}
    }catch{
        $conversionError=$_.Exception.Message
        if($formatStarted){
            try{
                $Progress.Invoke(0,100,'Conversion failed; restoring the complete original file system',$false)
                $actualDisk=Get-Disk -Number $disk.Number -ErrorAction Stop
                if([string]$actualDisk.UniqueId -cne [string]$Request.target.diskUniqueId){throw 'The disk identity changed; automatic restore was stopped.'}
                [PartlyDiskIo]::RestoreStagedVolume([int]$disk.Number,[string]$volume.Path,[long]$partition.Offset,[long]$partition.Size,$image,$Progress)
                Update-HostStorageCache -ErrorAction SilentlyContinue
            }catch{throw ('Conversion failed and automatic restore could not finish. Preserve the recovery image '+$image+' and journal '+$journal+'. '+$_.Exception.Message)}
        }
        throw ('Conversion failed; the original file system was restored from its verified image. '+$conversionError)
    }
}
function Assert-DestinationRange($Disk, [long]$Offset, [long]$Size, $ExcludedPartition = $null) {
    if ($Offset -lt 1MB -or $Size -lt 1MB -or $Offset % 1MB -ne 0 -or $Size % [long]$Disk.LogicalSectorSize -ne 0 -or $Offset + $Size -gt [long]$Disk.Size - 1MB) { throw 'The partition destination is outside the usable aligned disk area.' }
    if ([string]$Disk.PartitionStyle -eq 'MBR' -and $Offset + $Size -gt 2199023255552) { throw 'MBR volumes cannot extend beyond 2 TiB.' }
    foreach ($partition in @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop)) {
        if ($ExcludedPartition -and $partition.PartitionNumber -eq $ExcludedPartition.PartitionNumber) { continue }
        if ($Offset -lt [long]$partition.Offset + [long]$partition.Size -and $Offset + $Size -gt [long]$partition.Offset) { throw 'The selected destination overlaps another existing partition.' }
    }
}
function Convert-Hex([string]$Value) {
    if ($Value -notmatch '^(?:[0-9a-fA-F]{2})+$') { throw 'Sector data must be complete hexadecimal bytes.' }
    $bytes = New-Object byte[] ($Value.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) { $bytes[$index] = [Convert]::ToByte($Value.Substring($index * 2, 2), 16) }
    return ,$bytes
}

try {
    if (-not (Test-Administrator)) { throw 'Run Partly 20 as administrator for raw disk operations.' }
    Import-Module Storage -ErrorAction Stop
    $request = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $write = $Action -in @('writeSectors', 'move', 'copy', 'convert')
    $target = Get-Target $request.target $write $write
    $disk = $target.disk; $partition = $target.partition; $volume = $target.volume; $sector = $target.sectorSize
    if ($write) {
        $numbers = @([int]$disk.Number)
        if ($Action -eq 'copy') { $numbers += [int]$request.params.destination.diskNumber }
        Assert-Snapshot $request $numbers
    }
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
    $progressCallback = [Action[long,long,string,bool]] {
        param($Completed, $Total, $Message, $Cancellable)
        $percent = $(if ($Total -gt 0) { [math]::Min(100, [math]::Round(100.0 * $Completed / $Total, 2)) } else { 0 })
        [Console]::Error.WriteLine('PARTLY20_PROGRESS:' + (@{ completed = $Completed; total = $Total; percent = $percent; message = $Message; cancellable = $Cancellable } | ConvertTo-Json -Compress))
    }
    if ($CancellationFile -and (Test-Path -LiteralPath $CancellationFile)) { throw (New-Object OperationCanceledException('Operation cancelled before device access.')) }
    switch ($Action) {
        'sectors' {
            $first = Assert-Integer $request.params.sector 'Sector offset'
            $count = $(if ($null -eq $request.params.count) { 1 } else { Assert-Integer $request.params.count 'Sector count' 1 128 })
            $base = $(if ($partition) { [long]$partition.Offset } else { 0L })
            $length = $(if ($partition) { [long]$partition.Size } else { [long]$disk.Size })
            if ($first * $sector + $count * $sector -gt $length) { throw 'The requested sectors exceed the selected device range.' }
            $bytes = [PartlyDiskIo]::Read([int]$disk.Number, $base + $first * $sector, [int]($count * $sector))
            $rows = @(for ($offset = 0; $offset -lt $bytes.Length; $offset += 16) {
                $row = @($bytes[$offset..([math]::Min($bytes.Length - 1, $offset + 15))])
                @{ offset = [long]($base + $first * $sector + $offset); hex = (($row | ForEach-Object { '{0:X2}' -f $_ }) -join ' '); ascii = -join ($row | ForEach-Object { if ($_ -ge 32 -and $_ -le 126) { [char]$_ } else { '.' } }) }
            })
            $result = @{ success = $true; sector = $first; count = $count; logicalSectorSize = $sector; baseOffset = $base; hex = [BitConverter]::ToString($bytes).Replace('-', ''); rows = $rows; readOnly = $true }
        }
        'surface' {
            $base = $(if ($partition) { [long]$partition.Offset } else { 0L })
            $size = $(if ($partition) { [long]$partition.Size } else { [long]$disk.Size })
            $offset = $(if ($null -eq $request.params.offset) { 0L } else { Assert-Integer $request.params.offset 'Scan offset' })
            $length = $(if ($null -eq $request.params.length) { $size - $offset } else { Assert-Integer $request.params.length 'Scan length' 1 })
            if ($offset % $sector -ne 0 -or $length % $sector -ne 0 -or $offset + $length -gt $size) { throw 'The requested scan range must contain whole sectors inside the selected device.' }
            $scan = [PartlyDiskIo]::Scan([int]$disk.Number, $base + $offset, $length, $sector, $CancellationFile, $progressCallback)
            $result = @{ success = -not $scan.Cancelled; cancelled = $scan.Cancelled; readOnly = $true; totalBytes = $scan.TotalBytes; scannedBytes = $scan.ScannedBytes; badSectors = $scan.BadSectors; errors = @($scan.Errors.ToArray()); message = $(if ($scan.Cancelled) { 'Surface scan cancelled.' } else { "Surface scan complete. Unreadable sectors: $($scan.BadSectors)." }) }
        }
        'writeSectors' {
            if ($disk.IsBoot -or $disk.IsSystem) { throw 'Raw sector edits are blocked on disks containing the active Windows boot or system volume.' }
            $first = Assert-Integer $request.params.sector 'Sector offset'
            $original = Convert-Hex $request.params.originalHex; $replacement = Convert-Hex $request.params.newHex
            if ($original.Length -ne $replacement.Length -or $original.Length -lt $sector -or $original.Length % $sector -ne 0 -or $original.Length -gt 128 * $sector) { throw 'Edit between 1 and 128 complete sectors without changing their length.' }
            if ($first * $sector + $original.Length -gt [long]$partition.Size) { throw 'Sector edits must stay entirely within the selected data partition.' }
            $folder = Assert-LocalBackupFolder $request.params.backupDirectory ([int]$disk.Number) $original.Length
            $backupFile = Join-Path $folder ('Partly20-sectors-' + [guid]::NewGuid().ToString() + '.bin')
            $journal = New-RecoveryJournal $request @{ backupFile = $backupFile; absoluteOffset = [long]$partition.Offset + $first * $sector; byteCount = $original.Length }
            Assert-Snapshot $request @([int]$disk.Number)
            if ($CancellationFile -and (Test-Path -LiteralPath $CancellationFile)) { throw (New-Object OperationCanceledException('Sector edit cancelled before writing.')) }
            $progressCallback.Invoke(0,100,'Writing and verifying sector bytes. Cancellation is deferred until verification completes.',$false)
            [PartlyDiskIo]::WriteSectors([int]$disk.Number, [string]$volume.Path, [long]$partition.Offset + $first * $sector, $original, $replacement, $backupFile)
            $result = @{ success = $true; message = 'Sector changes were written and verified.'; backupFile = $backupFile; recoveryJournal = $journal; requiresRefresh = $true }
        }
        'move' {
            $newOffset = Assert-Integer $request.params.offset 'New partition offset' 1048576
            if ($newOffset -eq [long]$partition.Offset) { throw 'Choose a different partition starting position.' }
            Assert-DestinationRange $disk $newOffset ([long]$partition.Size) $partition
            $folder = Assert-LocalBackupFolder $request.params.stagingDirectory ([int]$disk.Number) ([long]$partition.Size)
            $imageFile = Join-Path $folder ('Partly20-move-' + [guid]::NewGuid().ToString() + '.img')
            $journal = New-RecoveryJournal $request @{ imageFile = $imageFile; originalOffset = [long]$partition.Offset; newOffset = $newOffset; size = [long]$partition.Size; fileSystem = [string]$volume.FileSystemType; sectorSize = $sector }
            Assert-Snapshot $request @([int]$disk.Number)
            [PartlyDiskIo]::Move([int]$disk.Number, [string]$volume.Path, [int]$partition.PartitionNumber, [long]$partition.Offset, [long]$partition.Size, $newOffset, $sector, [string]$volume.FileSystemType, $imageFile, $journal, $CancellationFile, $progressCallback)
            Update-HostStorageCache -ErrorAction SilentlyContinue
            $updated = Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Where-Object { [long]$_.Offset -eq $newOffset -and [long]$_.Size -eq [long]$partition.Size }
            if ($null -eq $updated) { throw 'The native move completed, but Windows did not report the new partition location. Preserve the recovery image and refresh the disks.' }
            $result = @{ success = $true; message = 'Partition data was moved, verified, and its starting position updated.'; imageFile = $imageFile; recoveryJournal = $journal; requiresRefresh = $true; newPartitionNumber = [int]$updated.PartitionNumber; newOffset = $newOffset }
        }
        'copy' {
            $destination = Get-Target $request.params.destination $false $true
            if ($destination.sectorSize -ne $sector) { throw 'Raw volume copies require matching logical sector sizes.' }
            $offset = Assert-Integer $request.params.destination.offset 'Destination offset' 1048576
            $size = Assert-Integer $request.params.destination.size 'Destination size' 1048576
            if ($size -ne [long]$partition.Size) { throw 'A volume clone must use exactly the source partition capacity. Extra unallocated space can be used after the copy.' }
            $desiredLabel = $request.params.destination.label
            if ($null -ne $desiredLabel) {
                $maximum = $(if ([string]$volume.FileSystemType -eq 'FAT32' -or [string]$volume.FileSystemType -eq 'FAT') { 11 } elseif ([string]$volume.FileSystemType -eq 'exFAT') { 15 } else { 32 })
                if (([string]$desiredLabel).Length -gt $maximum -or [string]$desiredLabel -match '[\\/:*?"<>|\x00-\x1f]') { throw 'The destination volume label is invalid for the copied file system.' }
            }
            if ($request.params.destination.fileSystem -and [string]$request.params.destination.fileSystem -ne [string]$volume.FileSystemType) { throw 'A raw volume clone retains the source file system. Convert it separately after copying.' }
            Assert-DestinationRange $destination.disk $offset $size
            $letter = Get-Letter $request.params.destination.driveLetter
            if ($letter -and ($letter -cnotmatch '^[A-Z]$' -or (Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue) -or @(Get-Partition -ErrorAction Stop | Where-Object { (Get-Letter $_.DriveLetter) -eq $letter }).Count)) { throw 'The destination drive letter is already in use.' }
            $journal = New-RecoveryJournal $request @{ sourceSize = $size; destination = $request.params.destination }
            Assert-Snapshot $request @([int]$disk.Number, [int]$destination.disk.Number)
            if ($CancellationFile -and (Test-Path -LiteralPath $CancellationFile)) { throw (New-Object OperationCanceledException('Copy cancelled before creating the destination partition.')) }
            # No existing destination partition is overwritten. A new identity is allocated first.
            $created = New-Partition -DiskNumber $destination.disk.Number -Offset $offset -Size $size -ErrorAction Stop
            $script:CreatedPartition = @{ diskNumber = [int]$created.DiskNumber; partitionNumber = [int]$created.PartitionNumber; offset = [long]$created.Offset; size = [long]$created.Size }
            $rawDestination = @($created | Get-Volume -ErrorAction Stop)[0]
            if ($null -eq $rawDestination -or -not [string]$rawDestination.Path) { throw 'Windows did not expose a lockable volume for the new destination partition. The empty partition has been preserved.' }
            [PartlyDiskIo]::Clone([int]$disk.Number, [string]$volume.Path, [long]$partition.Offset, [int]$destination.disk.Number, [string]$rawDestination.Path, $offset, $size, $sector, [string]$volume.FileSystemType, $CancellationFile, $progressCallback)
            Update-HostStorageCache -ErrorAction Stop
            $currentDestination = Get-Disk -Number $destination.disk.Number -ErrorAction Stop
            if ([string]$currentDestination.UniqueId -cne [string]$request.params.destination.diskUniqueId) { throw 'The destination disk identity changed after copying. No drive letter or label was changed.' }
            # UPDATE_PROPERTIES may renumber partitions. Never use a stale ordinal for follow-up writes.
            $matches = @(Get-Partition -DiskNumber $currentDestination.Number -ErrorAction Stop | Where-Object { [long]$_.Offset -eq $offset -and [long]$_.Size -eq $size })
            if ($matches.Count -ne 1) { throw 'The copied partition geometry changed. No drive letter or label was changed.' }
            $copied = $matches[0]
            if ([string]$created.Guid -and [string]$copied.Guid -cne [string]$created.Guid) { throw 'The copied partition identity changed. No drive letter or label was changed.' }
            $script:CreatedPartition.partitionNumber = [int]$copied.PartitionNumber
            if ($letter) { $copied | Set-Partition -NewDriveLetter ([char]$letter) -ErrorAction Stop | Out-Null }
            $copiedVolume = @($copied | Get-Volume -ErrorAction Stop)[0]
            if ([string]$copiedVolume.FileSystemType -ne [string]$volume.FileSystemType) { throw 'The copy bytes verified, but Windows could not mount the copied file system. Preserve the new partition and recovery journal.' }
            if ($null -ne $desiredLabel) { $copiedVolume | Set-Volume -NewFileSystemLabel ([string]$desiredLabel) -ErrorAction Stop | Out-Null }
            $result = @{ success = $true; message = 'The entire volume was copied and verified. The source was not changed.'; partition = $script:CreatedPartition; recoveryJournal = $journal; requiresRefresh = $true }
        }
        'convert' {
            if([string]$request.params.fileSystem -ne 'NTFS' -or [string]$volume.FileSystemType -notin @('FAT','FAT32')){
                $result=Invoke-StagedConversion $request $target $progressCallback
                break
            }
            if ([string]$request.params.fileSystem -cne 'NTFS' -or [string]$volume.FileSystemType -notin @('FAT', 'FAT32')) { throw 'Windows non-destructive conversion supports FAT and FAT32 volumes to NTFS.' }
            $letter = Get-Letter $partition.DriveLetter
            if (-not $letter) { throw 'Assign a drive letter before converting this file system.' }
            $journal = New-RecoveryJournal $request @{ originalFileSystem = [string]$volume.FileSystemType; targetFileSystem = 'NTFS' }
            Assert-Snapshot $request @([int]$disk.Number)
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = Join-Path $env:SystemRoot 'System32/convert.exe'
            $info.Arguments = $letter + ': /FS:NTFS /X'
            $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process; $process.StartInfo = $info
            if ($CancellationFile -and (Test-Path -LiteralPath $CancellationFile)) { throw (New-Object OperationCanceledException('Conversion cancelled before Windows started.')) }
            $progressCallback.Invoke(0, 100, 'Windows is converting FAT/FAT32 to NTFS. Cancellation is deferred until conversion completes.', $false)
            [void]$process.Start()
            $outputTask = $process.StandardOutput.ReadToEndAsync(); $errorTask = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine([string]$volume.FileSystemLabel)
            $process.StandardInput.WriteLine('N'); $process.StandardInput.Close()
            $process.WaitForExit()
            $output = $outputTask.Result; $errorOutput = $errorTask.Result; $exitCode = $process.ExitCode; $process.Dispose()
            Update-HostStorageCache -ErrorAction SilentlyContinue
            $actual = Get-Volume -DriveLetter $letter -ErrorAction Stop
            if ($exitCode -ne 0 -or [string]$actual.FileSystemType -ne 'NTFS') { throw ('Windows could not complete the conversion. ' + $output + ' ' + $errorOutput).Trim() }
            $result = @{ success = $true; message = 'Windows converted the file system to NTFS while retaining existing files.'; recoveryJournal = $journal; requiresRefresh = $true }
        }
    }
    $result | ConvertTo-Json -Depth 12 -Compress | Write-Output
    exit 0
} catch {
    $exception = $_.Exception
    while ($exception.InnerException -and ($exception -is [Reflection.TargetInvocationException] -or $exception -is [System.Management.Automation.MethodInvocationException])) { $exception = $exception.InnerException }
    $cancelled = $exception -is [OperationCanceledException]
    @{ success = $false; cancelled = $cancelled; error = @{ message = $exception.Message; code = 'ADVANCED_STORAGE_ERROR' }; message = $exception.Message; recoveryJournal = $script:RecoveryPath; createdPartition = $script:CreatedPartition; requiresRefresh = $Action -in @('writeSectors', 'move', 'copy', 'convert') } | ConvertTo-Json -Depth 8 -Compress | Write-Output
    exit 1
}
