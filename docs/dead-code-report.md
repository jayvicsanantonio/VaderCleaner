# Dead Code Report

Generated with Periphery 3.7.4, scanning the `VaderCleaner` scheme with test
targets **included** in indexing (so test code counts as real usage).

Command:
```
periphery scan --project VaderCleaner.xcodeproj --schemes VaderCleaner \
  --clean-build -- CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

**132 findings.** Verify before deleting — see the false-positive notes.

## Confidence

Cross-validated against a test-*excluded* run (133 findings). The two agree on
all but one item — `ManagerItemTable.nsColor`, which the test-inclusive run
clears because a test references it. This stability means the findings below are
authoritative: every remaining finding is unreferenced by both production **and**
test code.

## Important caveats

- **C-interop structs are false positives.** Fields exist for binary memory
  layout even when Swift never reads them (see `SMCReader` below).
- **Structural declarations** (XPC protocol methods, DI protocol seams) are
  confirmed unreferenced even by tests, but exist by design — judgment calls,
  not mechanical deletions.

---

## 1. High confidence — orphaned feature code (safe to remove)

These clusters are unreferenced anywhere except stale doc comments. They are
leftovers from refactors (the "detail screen" views were replaced by the
Applications summary-grid flow; `FileIconCache` was replaced by `AppIconCache`).

### `FileIconCache.swift` — entire file dead (superseded by `AppIconCache`)
Only mention is a doc comment in `AppIconCache.swift:16`. 15 findings covering
the class, init, enum cases, `LoadedIcon`, and all methods/properties.

### `AppUninstallerView` cluster (old detail screen)
- `AppUninstallerView.swift:10` — `AppUninstallerView`
- `AppUninstallerViewSubviews.swift` — `AppUninstallerProgressState` (16),
  `AppUninstallerListPane` (32), `AppUninstallerSearchField` (89),
  `AppUninstallerListRow` (108), `AppUninstallerEmptyListState` (146),
  `AppUninstallerCompleteState` (384), `AppUninstallerFailedState` (447)
- `ApplicationsView.swift` uses `AppUninstallerViewModel`, not the View.

### `AppUpdaterView` cluster (old detail screen)
- `AppUpdaterView.swift` — `AppUpdaterView` (6), `AppUpdaterProgressState` (59),
  `AppUpdaterUpToDateState` (75), `AppUpdaterListState` (108),
  `AppUpdaterRow` (203), `AppUpdaterFailedState` (274)

### `ExtensionsManagerView` cluster (0 references anywhere)
- `ExtensionsManagerView.swift:9` — `ExtensionsManagerView`
- `ExtensionsManagerViewSubviews.swift` — `ExtensionsManagerFormatting` (6),
  `ExtensionsManagerProgressState` (15), `ExtensionsManagerEmptyState` (31),
  `ExtensionsManagerList` (64), `ExtensionsManagerRow` (100),
  `ExtensionsManagerFailedState` (149)

### Other orphaned views/types
- `ApplicationsDashboardSubviews.swift:391` — `ApplicationsCard`
- `SmartScanReviewHeader.swift:13` — `SmartScanReviewHeader`
- `LargeOldFilesViewSubviews.swift:36` — `LargeOldFilesActions` enum

---

## 2. Medium confidence — unused members in live types

Verify these aren't part of a public/protocol API before removing.

### Unused functions
- `AppDiscovery.swift:17` `installedApps(includingSystemApps:)`, `:23` `bundleSize(at:)`
- `ExtensionDiscovery.swift:12` `extensions()`
- `FileScanner.swift:133` `scan(roots:excluding:batchSize:onBatch:)`, `:266` `recursiveSize(of:excluding:progress:)`
- `UnsupportedAppScanner.swift:92` `scan(apps:)`
- `MyClutterManagerModel.swift:135` `bytes(of:)`
- `MyClutterViewModel.swift:153` `toggleSelection(path:)`
- `PrivacyViewModel.swift:517` `deselectAll()`, `:524` `setChecked(_:browser:category:)`, `:530` `setClearRecents(_:)`
- `ScanProgressFormatting.swift:66` `filesScanned(_:)`
- `SmartScanViewSubviews.swift:366` `willExecute(_:)`
- `LargeOldFilesViewSubviews.swift:22` `accessDate(_:)`, `:27` `selectionLabel(for:)`
- `DeviceBatteryMonitor.swift:75`, `HungAppMonitor.swift:86`, `TrashSizeMonitor.swift:66`,
  `TrashedAppMonitor.swift:72` — `stop()` (monitor lifecycle; verify not called dynamically)

### Unused properties
- `os.Logger` instances never read: `AppStoreUpdateChecker.swift:22`,
  `AssociatedFileFinder.swift:27`, `BrowserDataCounter.swift:40`,
  `MailReindexer.swift:19`, `RecentFilesManager.swift:32`, `SparkleUpdateChecker.swift:24`
- `HealthMonitorViewModel.swift` color helpers (45–66): `cpuColor`, `ramPressureColor`,
  `diskColor`, `batteryColor`, `smartColor`, `fileVaultColor`
- `HealthMonitorView.swift:592` `color`, `ApplicationsManagerView.swift:32` `selectionFill`
  (note: `ManagerItemTable.swift:611 nsColor` was flagged in the test-excluded run
  but is referenced by tests — **not** dead)
- `MenuBarViewModel.swift:69` `memoryUsedPercent`
- `SystemJunkViewModel.swift:114` `formattedTotalSelectedSize`, `:272` `byteFormatter`
- `SmartScanViewModel.swift:887` `maintenanceScriptsSupported`
- `VaderTheme.swift:13` `vaderSpaceBlack`, `:15` `vaderDeepRed` (design tokens — may be intentional)
- `LargeOldFilesViewSubviews.swift:15` `dateFormatter`

### Unused enum cases / parameters
- `LargeOldFilesViewSubviews.swift:170` case `deleting`
- `LoginItem.swift:77` param `item`, `NotificationManager.swift:269` param `totalBytes`

---

## 3. Low priority — assign-only properties

Assigned but never read. Some are intentional (state kept for Combine/SwiftUI
observation). Review individually.

- `CleanupGroup.swift:140` `files`
- `MyClutterManagerView.swift:15,102–112` — `initialCategory`, `category`, `facet`,
  `browser`, `search`, `sort`, `resultsVersion`, `cacheLoading`, `selectionStamp`
- `PerformanceRecommendationEngine.swift:19–33` — `detail`, `icon`, `actionLabel`, `memory`
- `SpaceLensBubbleView.swift:15` `node`

---

## 4. FALSE POSITIVES / structural — do NOT mechanically remove

These remain flagged even with tests indexed, but should not be deleted as
ordinary dead code.

### `SMCReader.swift` C-interop struct fields (13 findings) — hard false positive
`major`, `minor`, `build`, `reserved`, `release`, `version`, `length`,
`cpuPLimit`, `gpuPLimit`, `memPLimit`, `dataAttributes`, `status`, `data8`, `data32`
are fields of `SMCKeyData`/`SMCKeyDataVersion`/`SMCKeyDataPLimit`, passed to IOKit
via `MemoryLayout<SMCKeyData>.stride`. Their presence is required for correct
binary layout even though Swift never reads them. **Keep as-is.**

### Structural / interface declarations (confirmed unreferenced, but by design)
- `HelperProtocol.swift:113`, `VaderCleanerHelper/main.swift:47`, and 8 test spies —
  `removeLoginItem(path:reply:)`. Part of the XPC helper interface; no caller in app
  or tests. Genuinely removable, but only by touching the protocol + helper + all
  spies together — treat as a deliberate interface change, not a quick delete.
- `BrowserDetector.swift:10,18` `BrowserDetecting`, `DiskScanner.swift:11,58` `DiskScanning`
  — "redundant protocol / never used as an existential type": the concrete type is
  always used directly, so the protocol adds no value today. These are DI seams;
  keep if you want the injection point, drop the protocol if you don't.
- `TestHelpersTests.swift:5` unused `import VaderCleaner` (safe to remove — test file).
