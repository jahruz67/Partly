# Partly 20

A local Windows 10/11 disk and partition manager recreated from the supplied screen recording. No account, sign-in, cloud service, or telemetry. The desktop app reads actual Windows disks through the Windows Storage module.

## Run

Open `dist/Partly 20.exe` after building. Windows requests administrator access so storage operations are available. The unsigned executable is a local build.

From source, install Node.js 22 or later and pnpm, then run:

```powershell
pnpm install
pnpm start
```

For administrator access from source:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Partly20.ps1 -AsAdministrator
```

## Use

Select a partition or unallocated region in the disk map. Choose an operation, fill in its values, and select **Place in queue**. The map previews the pending layout. Undo, redo, and discard are available before applying. **Apply** opens a before/after review and then a native final confirmation before any disk writes.

The recording's 85 observed controls are catalogued in `tests/video-features.json`. The account/profile/sign-out flow is intentionally excluded by request. The controls that were marked Demo in the reference have local implementations rather than demo tooltips.

Partition tools include create, resize, move, raw volume copy, format, immediate or queued delete, drive letters, labels, properties, hide/unhide, file-system check, full surface scan, file-system conversion, lost-volume recovery, and sector viewing/editing. Advanced formatting includes allocation size, quick/full format, and NTFS compression. The operation review supports selectable operations, before/after maps, undo/redo/discard, notifications, cancellation, and optional shutdown on successful completion. Cancellation waits for a safe operation boundary; completed changes cannot be undone.

Moving requires a full verified staging image on another physical disk. The image, original layout, and recovery journal are retained. Volume copy preserves the source file system and files while assigning a distinct volume/partition identity. Lost-volume recovery requires corroborating backup-boot or file-system metadata; ambiguous headers cannot be recovered. Sector edits require an original-byte comparison and backup on another physical disk.

Windows boot, operating system, EFI, recovery, reserved, read-only, and encrypted partitions are protected from direct editing. Offline or unhealthy disks and Storage Spaces are excluded from writes. Resizing follows Windows-supported limits. FAT/FAT32-to-NTFS conversion uses the native Windows converter. Other conversions among NTFS, exFAT, and FAT32 use a complete verified recovery image plus verified file staging on another NTFS disk, recreate the target file system, then restore and verify every file. The original recovery image and staging files are retained. Unsupported alternate streams, EFS encryption, and reparse points are rejected before formatting; NTFS-only metadata changes require explicit acknowledgement. FAT32 capacity/file-size limits and staging capacity are checked. Drives with encryption status Windows cannot verify are blocked from writes. Unformatted data partitions can be deleted after their encryption status is verified.

The expanded navigation includes Backup & Recovery, V2V Migration, disk tools, history, help, and Settings & Tools. The operations menu provides Windows discovery/copying, file/folder copying, and refresh. Settings include automatic update checks, progress auto-close, automatic inventory reload, language/region, SMTP email notifications, desktop notifications, recovery media, diagnostic ZIP collection, issue reports, device-ID copying, privacy information, and update checking.

WIM backup uses a consistent Windows VSS snapshot and DISM. WIM restore targets an empty NTFS data volume. Windows copying creates EFI/MSR/Windows partitions and UEFI boot files on an empty destination disk. Native VHD/VHDX conversion uses the Windows virtual-disk engine. Windows system-image backup uses wbadmin when present. Recovery media can use the built-in Windows Recovery Drive wizard.

Optional tool requirements are shown in the app: custom WinPE ISO/USB creation needs the Microsoft Windows ADK and WinPE add-on; VMDK/VDI/QCOW2 formats need a locally installed QEMU tool; physical-to-virtual capture uses signed Microsoft Disk2vhd with explicit download and license acceptance. No published update server is invented for this local build: automatic/manual checks use the local or HTTPS release manifest you configure, with SHA-256 package verification.

Settings, diagnostic exports, and operation history stay on this computer. SMTP passwords are encrypted using Windows credential protection. Email is sent only after you configure and enable it. Issue reports are saved locally and are not uploaded. Settings and history are stored under the Windows user application data folder for Partly 20. Pending operations are kept only in memory to avoid replaying an outdated disk layout.

## Automated releases and website

Push this repository to GitHub to activate `.github/workflows/release.yml`. Each branch push builds the pushed revision on Windows, runs the source checks, Node tests, and Windows fixtures, then publishes a release tagged `build-<full commit SHA>`. A push containing several commits builds the final commit of that push. Local commits trigger builds once pushed. You can also run the workflow manually from **Actions → Build and release Windows app → Run workflow**.

Releases contain `Partly-20-windows-x64.exe` and `SHA256SUMS.txt`. Builds from other branches are prereleases; the current default-branch build becomes the latest release. Older builds are allowed to finish without replacing the latest default-branch download. Rerunning a published commit preserves its assets. A prerelease is promoted when the same commit reaches the default branch. The workflow uses GitHub's built-in token and needs no personal access token or signing secrets. Executables remain unsigned.

The static download website is in `docs/`. To publish it:

1. Push these files to `master` (or your repository's default branch).
2. Open **Settings → Pages** in GitHub.
3. Choose **Deploy from a branch**, select **master** and **/docs**, then **Save**. If you use a different default branch, select that branch instead.

For this repository, the site address is `https://jahruz67.github.io/Partly/`. GitHub Pages republishes when you push changes to `docs/`. No website build, custom domain, or separate deployment workflow is required. See [GitHub's publishing-source instructions](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site).

The website's download button follows GitHub's latest release and becomes usable after the first successful default-branch release. All builds and checksums are linked separately. If you fork or rename the repository, update the GitHub links in `docs/index.html`. The website is a download and information page; disk operations run in the Windows desktop app.

## Local verification

All application source was completed before the first application build.

```powershell
pnpm check
pnpm test
powershell -NoProfile -File .\tests\advanced-native-fixtures.ps1
powershell -NoProfile -File .\tests\conversion-file-fixtures.ps1
powershell -NoProfile -File .\tests\virtualdisk-file-test.ps1
pnpm build
```

The build creates a portable 64-bit Windows executable in `dist/`. Packaged PowerShell sources are separate resources so Windows can execute them. Tests cover queue validation and coordination, boot records, file-system recovery metadata, native virtual-disk conversion round trips on unattached files, settings/updates, actual file-copy verification, and diagnostic ZIP creation. Existing user disks are never modified by the tests. Physical write paths still require validation on a disposable attached disk or VM before relying on them for valuable data.

The explicit `?preview=1` URL is a browser-only visual preview using reference disk data. It cannot write to disks. The desktop app always uses the real Windows storage bridge.

Implementation references: [Windows Storage commands](https://learn.microsoft.com/en-us/powershell/module/storage/) and [Electron security](https://www.electronjs.org/docs/latest/tutorial/security).
