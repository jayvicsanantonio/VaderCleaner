# VaderCleaner — Implementation Plan

## Overview

This plan breaks the VaderCleaner macOS app (spec.md) into 27 incremental prompts for a code-generation LLM. Each prompt builds on the previous, ends with everything wired together, and follows TDD — tests are written before implementation code in every step.

---

## Coding Conventions (apply to every prompt)

- Every code file begins with a 2-line comment: line 1 is the file name/purpose, line 2 is a brief description of what it does.
- Simple, clean, readable code over clever or complex code.
- No mock implementations — always use real APIs and real data.
- Match surrounding code style and formatting within each file.
- No comments that describe what code does — only comments that explain non-obvious WHY.

---

## Architectural Decisions

### Privileged Helper Tool
Many features require root-level access (clearing system caches, removing system launch agents, running maintenance scripts, accessing protected directories). VaderCleaner uses a **privileged XPC helper tool** installed via `SMAppService`. The main app communicates with the helper over XPC to perform privileged operations. This is established in Prompt 3 and used throughout.

### ClamAV via Homebrew
Rather than bundling ClamAV (which requires managing a large binary and database updates), VaderCleaner checks for a Homebrew-installed ClamAV on first use of the Malware feature. If not found, it guides the user to install it. Database updates are triggered via `freshclam`.

### Full Disk Access (FDA)
Reading browser data, Mail attachments, Trash, and other protected locations requires FDA. The app detects FDA status on launch and shows an onboarding prompt to guide the user through System Settings if it is not granted.

### Test Strategy
- **Unit tests:** XCTest, pure logic, no disk I/O
- **Integration tests:** Real file system operations in temporary directories
- **UI tests:** XCUITest for critical user flows (scan → preview → clean)

---

## Phase 0 — Foundation

### Prompt 1 — Xcode Project + Test Infrastructure

```
Create a new macOS Xcode project named "VaderCleaner" using SwiftUI.

Requirements:
- Minimum deployment target: macOS 14.0
- Swift language version: Swift 5.9
- Bundle identifier: com.personal.VaderCleaner
- Add an XCTest unit test target named "VaderCleanerTests"
- Add an XCUITest UI test target named "VaderCleanerUITests"
- Add a shared test utilities file at Tests/Helpers/TestHelpers.swift with:
  - A helper that creates a temporary directory and returns its URL
  - A helper that tears down (deletes) a temporary directory
  - A helper that creates dummy files of a given size in a directory
- Verify the project builds and both test targets run (empty) without errors

Every Swift file must start with a 2-line comment:
// <filename>.swift
// <one-line description of what this file does>

Do not add any features yet. The deliverable is a clean, building project with a working test harness.
```

---

### Prompt 2 — App Shell & Sidebar Navigation

```
Building on the VaderCleaner Xcode project from Prompt 1, implement the main app shell with sidebar navigation.

Write failing tests first (in VaderCleanerTests), then implement:

Tests to write first:
- Test that NavigationSection enum contains all 12 expected cases (SmartScan, SystemJunk, LargeOldFiles, SpaceLens, MalwareRemoval, Privacy, Extensions, AppUninstaller, AppUpdater, Optimization, HealthMonitor, Notifications... wait, Notifications is not a sidebar section)

Actually the sidebar sections from the spec are:
1. Smart Scan
2. System Junk
3. Large & Old Files
4. Space Lens
5. Malware Removal
6. Privacy
7. Extensions
8. App Uninstaller
9. App Updater
10. Optimization
11. Health Monitor

- Test that each NavigationSection has a non-empty title string
- Test that each NavigationSection has a valid SF Symbol icon name

Implementation:
- Define a NavigationSection enum with all 11 cases, each with a title and SF Symbol icon name
- Create the main app window using NavigationSplitView:
  - Left sidebar lists all 11 sections with icon + label
  - Selecting a section shows its placeholder view in the detail area
  - Default selection is Smart Scan
- Each placeholder detail view shows the section title centered with a "Coming Soon" label
- The app window has a minimum size of 900×600
- Wire NavigationSection into the app's main ContentView

The app should launch, show the sidebar, and navigate between placeholder sections.
```

---

### Prompt 3 — Privileged Helper Tool Architecture

```
Building on Prompt 2, establish the privileged XPC helper tool architecture that will underpin all system-level operations in VaderCleaner.

Write failing tests first, then implement:

Tests to write first:
- Test that VaderCleanerHelperProtocol defines all required XPC methods (use protocol conformance checks)
- Test that HelperConnectionManager can be instantiated
- Test that HelperConnectionManager exposes a connect() method
- Test that the XPC connection uses the correct mach service name

Implementation:
1. Add a new macOS Command Line Tool target named "VaderCleanerHelper" to the Xcode project
2. Define a shared XPC protocol file at Shared/HelperProtocol.swift:
   - Protocol named VaderCleanerHelperProtocol
   - Methods (all async/reply-based):
     - deleteFiles(_ paths: [String], reply: @escaping (Error?) -> Void)
     - runMaintenanceScripts(reply: @escaping (Error?) -> Void)
     - removeLoginItem(path: String, reply: @escaping (Error?) -> Void)
     - removeLaunchAgent(path: String, reply: @escaping (Error?) -> Void)
     - flushInactiveMemory(reply: @escaping (Error?) -> Void)
3. Implement the helper tool in VaderCleanerHelper/main.swift:
   - NSXPCListener on a mach service name "com.personal.VaderCleaner.helper"
   - Implements VaderCleanerHelperProtocol
   - deleteFiles: removes files at given paths using FileManager
   - runMaintenanceScripts: runs `periodic daily weekly monthly` via Process
   - removeLoginItem / removeLaunchAgent: deletes the file at path
   - flushInactiveMemory: calls `purge` command via Process
4. In the main app, create HelperConnectionManager.swift:
   - Singleton that manages the NSXPCConnection to the helper
   - connect() establishes the connection
   - Exposes the proxy as VaderCleanerHelperProtocol
   - Handles connection interruption and invalidation with reconnect logic
5. Add a launchd plist for the helper at VaderCleanerHelper/com.personal.VaderCleaner.helper.plist
6. Register the helper installation using SMAppService in the app's AppDelegate/App init

The helper must be code-signed. Document in a comment the manual codesigning step required during development.
```

---

### Prompt 4 — Full Disk Access Detection & Onboarding

```
Building on Prompt 3, add Full Disk Access (FDA) detection and an onboarding flow to guide the user if FDA is not granted.

Write failing tests first, then implement:

Tests to write first:
- Test that PrivacyPermissionChecker.hasFullDiskAccess() returns a Bool
- Test that attempting to read a protected path returns false when access is denied (use a path known to require FDA)
- Test that PermissionOnboardingViewModel has an isDismissed state
- Test that PermissionOnboardingViewModel.openSystemSettings() triggers the correct URL

Implementation:
- Create PrivacyPermissionChecker.swift with a static method hasFullDiskAccess() -> Bool that attempts to read ~/Library/Application Support/com.apple.TCC/TCC.db and returns whether access succeeded
- Create PermissionOnboardingView.swift: a sheet/overlay that explains why FDA is needed, shows the steps to enable it, and has an "Open System Settings" button that opens x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles and a "Check Again" button that re-checks and dismisses if granted
- In the main App entry point, check FDA on launch and store result in AppState
- Show the onboarding sheet if FDA is not granted
- AppState (an ObservableObject) holds hasFullDiskAccess: Bool, refreshed on foreground
- Wire AppState into the environment so all feature views can check FDA status before scanning
```

---

### Prompt 5 — Menu Bar Extra

```
Building on Prompt 4, add the always-on menu bar extra.

Write failing tests first, then implement:

Tests to write first:
- Test that MenuBarViewModel initializes with default stat values
- Test that MenuBarViewModel.formattedRAMUsage returns a non-empty string
- Test that MenuBarViewModel.formattedDiskSpace returns a non-empty string

Implementation:
- Modify the app entry point to use @main with both a WindowGroup (main window) and a MenuBarExtra
- MenuBarExtra label: displays "RAM: X.X GB | Disk: XX GB free" (placeholder values for now, real stats wired in Prompt 10)
- Clicking the menu bar icon opens a popover with:
  - RAM usage row (label + value)
  - Disk space row (label + value)
  - Divider
  - "Open VaderCleaner" button that brings the main window to front
  - "Quit VaderCleaner" button
- Create MenuBarViewModel.swift as an ObservableObject with formattedRAMUsage and formattedDiskSpace string properties (hardcoded placeholder values for now)
- The menu bar extra persists when the main window is closed (app does not quit when window closes)
- Set LSUIElement = YES in Info.plist so the app does not appear in the Dock when only the menu bar is showing (but does show in Dock when the main window is open — use NSApp.setActivationPolicy accordingly)
```

---

### Prompt 6 — Preferences Model & Window

```
Building on Prompt 5, implement the Preferences model and window.

Write failing tests first, then implement:

Tests to write first:
- Test that PreferencesStore loads default values correctly (all notifications on, disk threshold 10%)
- Test that PreferencesStore persists a value to UserDefaults and reads it back
- Test that ExclusionsStore can add a path
- Test that ExclusionsStore can remove a path
- Test that ExclusionsStore does not add duplicate paths
- Test that ExclusionsStore persists paths across instantiation

Implementation:
- Create PreferencesStore.swift (ObservableObject, @AppStorage backed):
  - notifyLowDisk: Bool = true
  - notifyHighRAM: Bool = true
  - notifyMalwareFound: Bool = true
  - notifyLargeFilesFound: Bool = true
  - diskSpaceThresholdPercent: Double = 10.0
  - launchAtLogin: Bool = true
  - showMenuBar: Bool = true
- Create ExclusionsStore.swift (ObservableObject, UserDefaults backed):
  - exclusions: [String] (array of absolute paths)
  - add(path: String)
  - remove(path: String)
- Create PreferencesView.swift with four tabs:
  - Notifications: toggle for each notification type, slider/stepper for disk threshold
  - Exclusions: list of excluded paths with add (+) and remove (-) buttons, file picker for adding
  - Startup: toggle for launchAtLogin
  - Menu Bar: toggle for showMenuBar (hides/shows the menu bar extra)
- Open PreferencesView as a Settings scene (SwiftUI Settings{} in App body)
- Inject PreferencesStore and ExclusionsStore as environment objects throughout the app
```

---

### Prompt 7 — Launch at Login

```
Building on Prompt 6, implement the launch-at-login functionality wired to the Preferences toggle.

Write failing tests first, then implement:

Tests to write first:
- Test that LoginItemManager.setEnabled(true) does not throw
- Test that LoginItemManager.setEnabled(false) does not throw
- Test that LoginItemManager.isEnabled returns a Bool

Implementation:
- Create LoginItemManager.swift using SMAppService.mainApp (ServiceManagement framework, macOS 13+):
  - static func setEnabled(_ enabled: Bool) throws
  - static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
- In PreferencesStore, add a didSet observer on launchAtLogin that calls LoginItemManager.setEnabled()
- On app launch, sync the launchAtLogin preference with the actual SMAppService status and correct any mismatch
- Handle errors from SMAppService gracefully with a user-facing alert
- Wire PreferencesView's Startup toggle so toggling it calls through to SMAppService immediately
```

---

## Phase 1 — System Stats & Health Monitor

### Prompt 8 — System Stats Service

```
Building on Prompt 7, implement the system stats data layer. No UI yet — this is purely the data/service layer.

Write failing tests first, then implement:

Tests to write first:
- Test that SystemStatsService.cpuUsage returns a Double between 0 and 1
- Test that SystemStatsService.ramUsage returns a MemoryStats with usedBytes and totalBytes > 0
- Test that SystemStatsService.diskSpace returns a DiskStats with usedBytes and totalBytes > 0
- Test that SystemStatsService.batteryHealth returns a BatteryStats (or nil on non-laptop)
- Test that MemoryStats.pressureLevel returns one of: .nominal, .fair, .critical
- Test that SystemStatsService updates stats on a timer (mock the timer in tests)

Implementation:
- Create SystemStatsService.swift as an ObservableObject with a 2-second polling timer:
  - cpuUsage: Double (0.0–1.0) via host_processor_info
  - ramUsage: MemoryStats via host_statistics64
  - diskSpace: DiskStats via FileManager.attributesOfFileSystem
  - batteryHealth: BatteryStats? via IOKit (cycle count, max capacity %, condition string)
  - diskSMARTStatus: SMARTStatus (.good / .failing / .unknown) via IOKit SMART data
  - fileVaultEnabled: Bool via fdesetup or diskutil cs info parsing
- Define value types: MemoryStats, DiskStats, BatteryStats, SMARTStatus, MemoryPressureLevel
- Publish all values via @Published
- Inject SystemStatsService as an environment object in the App entry point
```

---

### Prompt 9 — Health Monitor UI

```
Building on Prompt 8, implement the Health Monitor feature view wired to SystemStatsService.

Write failing tests first, then implement:

Tests to write first:
- Test that HealthMonitorViewModel correctly formats CPU % string from a 0.0–1.0 Double
- Test that HealthMonitorViewModel correctly formats RAM GB string from byte counts
- Test that HealthMonitorViewModel correctly formats disk space string
- Test that BatteryStats with condition "Good" produces a green status color
- Test that SMARTStatus.failing produces a red status color

Implementation:
- Create HealthMonitorViewModel.swift (ObservableObject) that consumes SystemStatsService and exposes formatted display strings and status colors
- Create HealthMonitorView.swift replacing the placeholder:
  - Card-style grid layout with 5 cards: Battery Health, Disk Health (SMART), RAM Pressure, CPU Load, Disk Space
  - Each card shows: icon, label, value, status indicator (color dot: green/yellow/red)
  - Battery card: cycle count, max capacity %, condition
  - Disk SMART card: Good / Failing / Unknown
  - RAM card: used/total GB, pressure level badge
  - CPU card: % usage, bar indicator
  - Disk Space card: used/total GB, % used bar
  - FileVault status shown as an info row at the bottom of the view
- Wire HealthMonitorView into the NavigationSection.healthMonitor detail view
```

---

### Prompt 10 — Menu Bar Live Stats

```
Building on Prompt 9, wire real system stats into the menu bar extra.

Write failing tests first, then implement:

Tests to write first:
- Test that MenuBarViewModel.formattedRAMUsage correctly formats MemoryStats
- Test that MenuBarViewModel.formattedDiskSpace correctly formats DiskStats
- Test that menu bar label truncates gracefully when values are large

Implementation:
- Update MenuBarViewModel to subscribe to SystemStatsService (injected via environment or passed in init)
- Menu bar label displays: "RAM: X.XGB  Disk: XXGB" updated every 2 seconds
- Menu bar popover shows:
  - RAM: used / total with pressure level indicator
  - Disk: used / total / % free
  - CPU: current %
  - Battery: health % (if applicable)
- All values update live from SystemStatsService
- Replace placeholder strings from Prompt 5 with real data
```

---

### Prompt 11 — Notification System

```
Building on Prompt 10, implement the notification system wired to SystemStatsService thresholds and PreferencesStore toggles.

Write failing tests first, then implement:

Tests to write first:
- Test that NotificationManager.requestPermission() completes without error
- Test that NotificationThresholdMonitor triggers low disk notification when disk < threshold
- Test that NotificationThresholdMonitor does not trigger if notification is disabled in preferences
- Test that NotificationThresholdMonitor does not re-trigger within a cooldown period (5 minutes)
- Test that NotificationManager.sendMalwareDetectedNotification(threatName:) creates a notification with the correct title

Implementation:
- Create NotificationManager.swift:
  - requestPermission() async
  - sendLowDiskNotification(freePercent: Double)
  - sendHighRAMNotification(pressureLevel: String)
  - sendMalwareDetectedNotification(threatName: String)
  - sendLargeFilesFoundNotification(count: Int, totalSize: Int64)
- Create NotificationThresholdMonitor.swift (ObservableObject):
  - Observes SystemStatsService
  - Checks disk threshold against PreferencesStore.diskSpaceThresholdPercent
  - Checks RAM pressure level
  - Has per-notification cooldown (5 minutes) to avoid spamming
  - Respects all PreferencesStore notification toggles
- Request notification permission on first launch (after FDA onboarding)
- Inject NotificationThresholdMonitor into the app environment
- Malware and large-files notifications are triggered by their respective feature modules (stubs for now, wired in later prompts)
```

---

## Phase 2 — File Cleaning

### Prompt 12 — File Scanner Infrastructure

```
Building on Prompt 11, implement the shared file scanner infrastructure used by System Junk, Large & Old Files, and other scanning features.

Write failing tests first (all using real temporary directories from TestHelpers), then implement:

Tests to write first:
- Test that FileScanner enumerates files in a directory recursively
- Test that FileScanner respects the exclusions list (files in excluded paths are not returned)
- Test that FileScanner calculates total size correctly for a set of test files
- Test that ScanResult correctly aggregates items by category
- Test that FileScanner skips symlinks that point outside the scanned directory
- Test that FileScanner handles permission denied errors gracefully without crashing

Implementation:
- Create FileScanner.swift:
  - func scan(paths: [URL], excluding: [URL]) async throws -> [ScannedFile]
  - Uses FileManager enumerator with options: .skipsHiddenFiles off (we need hidden cache files), .skipsPackageDescendants on
  - Each ScannedFile has: url, size (bytes), lastAccessDate, lastModifiedDate, category: ScanCategory
- Create ScanCategory.swift enum: systemCache, userCache, systemLogs, userLogs, languageFiles, mailAttachments, iosBackups, trash, largeFile, oldFile
- Create ScanResult.swift: holds [ScannedFile], computed properties for totalSize, itemsByCategory, formattedTotalSize
- Exclusions: filter out any file whose path starts with an excluded path from ExclusionsStore
- Make FileScanner injectable for testing (protocol-backed)
```

---

### Prompt 13 — System Junk Scanner

```
Building on Prompt 12, implement the System Junk scanner that finds all junk categories.

Write failing tests first (using real temp directories), then implement:

Tests to write first:
- Test that SystemJunkScanner finds files in ~/Library/Caches
- Test that SystemJunkScanner finds files in /Library/Logs
- Test that SystemJunkScanner finds language .lproj bundles for non-system languages
- Test that SystemJunkScanner identifies iOS backup directories in ~/Library/Application Support/MobileSync/Backup
- Test that SystemJunkScanner finds items in ~/.Trash and /Volumes/*/Trash
- Test that SystemJunkScanner respects exclusions from ExclusionsStore
- Test that scan results are grouped correctly by ScanCategory

Implementation:
- Create SystemJunkScanner.swift using FileScanner:
  - Scans these paths and assigns categories:
    - ~/Library/Caches → .userCache
    - /Library/Caches → .systemCache (via privileged helper)
    - ~/Library/Logs → .userLogs
    - /Library/Logs → .systemLogs (via privileged helper)
    - ~/Library/Mail Downloads → .mailAttachments
    - ~/Library/Application Support/MobileSync/Backup → .iosBackups
    - Language .lproj directories in /Library and /System/Library for non-active locales → .languageFiles
    - ~/.Trash and Trash on all mounted volumes → .trash
  - Returns ScanResult with all findings grouped by category
- Privileged paths (system caches, system logs) are read via the helper tool (list directory contents), deletion via helper
```

---

### Prompt 14 — System Junk UI & Deletion

```
Building on Prompt 13, implement the System Junk feature view with scan → preview → clean flow.

Write failing tests first, then implement:

Tests to write first:
- Test that SystemJunkViewModel starts in idle state
- Test that SystemJunkViewModel transitions to scanning → preview states correctly
- Test that SystemJunkViewModel correctly computes total selected size when categories are toggled
- Test that SystemJunkViewModel.clean() calls deletion for only checked categories
- Test that SystemJunkViewModel transitions to complete state after clean
- UI test: tap Scan, wait for results, verify category list appears, tap Clean, verify confirmation

Implementation:
- Create SystemJunkViewModel.swift (ObservableObject):
  - State machine: .idle → .scanning → .preview(ScanResult) → .cleaning → .complete(bytesFreed)
  - checkedCategories: Set<ScanCategory> (all checked by default)
  - totalSelectedSize: Int64 (computed from checked categories)
  - scan() calls SystemJunkScanner
  - clean() calls FileManager.removeItem for unchecked files, privileged helper for system paths
- Create SystemJunkView.swift replacing the placeholder:
  - Idle state: centered Scan button with description text
  - Scanning state: progress spinner with "Scanning..." label
  - Preview state:
    - List of categories, each row: checkbox, category name, item count, size
    - Total selected size shown at bottom
    - "Clean" button (disabled if nothing selected)
    - "Re-scan" button
  - Cleaning state: progress indicator
  - Complete state: "X.X GB freed" confirmation with a "Scan Again" button
- Wire into NavigationSection.systemJunk
```

---

### Prompt 15 — Large & Old Files

```
Building on Prompt 14, implement the Large & Old Files feature.

Write failing tests first, then implement:

Tests to write first:
- Test that LargeOldFilesScanner finds files larger than the size threshold
- Test that LargeOldFilesScanner finds files not accessed within the age threshold
- Test that LargeOldFilesScanner respects exclusions
- Test that LargeOldFilesViewModel sorts results by size descending by default
- Test that LargeOldFilesViewModel can sort by last accessed date
- Test that LargeOldFilesViewModel correctly computes total selected size
- Test that deleting selected files removes them from the results list

Implementation:
- Create LargeOldFilesScanner.swift:
  - Scans ~/Documents, ~/Downloads, ~/Desktop, ~/Movies, ~/Music, ~/Pictures, and ~/Library
  - Size threshold: files > 50 MB
  - Age threshold: not accessed in 6+ months
  - Returns [ScannedFile] with .largeFile or .oldFile category
  - Respects exclusions
- Create LargeOldFilesViewModel.swift (ObservableObject):
  - State machine: .idle → .scanning → .results([ScannedFile]) → .empty
  - sortOrder: SortOrder (size desc, size asc, date asc, date desc, name)
  - selectedFiles: Set<URL>
  - deleteSelected() via FileManager (no privileged helper needed for user home files)
- Create LargeOldFilesView.swift:
  - Table with columns: Name, Size, Last Accessed, Path
  - Sortable column headers
  - Checkboxes for selection
  - "Delete Selected" button showing total selected size
  - Row shows file icon (NSWorkspace.icon), name, size, last accessed date
  - Right-click context menu: "Show in Finder", "Delete"
- Wire into NavigationSection.largeOldFiles
- Trigger NotificationManager.sendLargeFilesFoundNotification when scan finds results
```

---

### Prompt 16 — Space Lens Disk Scanner

```
Building on Prompt 15, implement the disk space tree scanner for the Space Lens feature.

Write failing tests first (using real temp directories), then implement:

Tests to write first:
- Test that DiskNode correctly computes size as sum of children for a directory
- Test that DiskScanner builds a correct tree for a known directory structure
- Test that DiskScanner handles symlinks without following them into infinite loops
- Test that DiskScanner handles permission-denied directories gracefully
- Test that DiskScanner reports progress as it scans

Implementation:
- Create DiskNode.swift:
  - class DiskNode: Identifiable, ObservableObject
  - Properties: id, url, name, size (bytes), isDirectory, children: [DiskNode]
  - Computed: formattedSize, percentOfParent(parent: DiskNode) -> Double
- Create DiskScanner.swift:
  - func scan(root: URL, progress: @escaping (Int) -> Void) async throws -> DiskNode
  - Recursive file system enumeration starting at root (default: volume root)
  - Skips symlinks to prevent cycles
  - Reports progress as file count processed
  - Handles permission errors by marking nodes as inaccessible (size = 0, note in node)
- DiskScannerViewModel.swift (ObservableObject):
  - root: DiskNode?
  - navigationPath: [DiskNode] (breadcrumb stack)
  - scanProgress: Double (0.0–1.0)
  - State machine: .idle → .scanning → .ready(DiskNode) → .error(String)
```

---

### Prompt 17 — Space Lens Treemap UI

```
Building on Prompt 16, implement the Space Lens treemap visualization.

Write failing tests first, then implement:

Tests to write first:
- Test that TreemapLayout.layout(nodes:in:) produces non-overlapping rectangles
- Test that TreemapLayout correctly sizes rectangles proportionally to node sizes
- Test that TreemapLayout handles single-node input
- Test that TreemapLayout handles empty input
- Test that DiskScannerViewModel.drillDown(into:) appends to navigationPath
- Test that DiskScannerViewModel.navigateUp() pops from navigationPath

Implementation:
- Create TreemapLayout.swift:
  - Squarified treemap algorithm
  - Input: [(id, weight)] and CGRect bounds
  - Output: [(id, CGRect)]
- Create TreemapView.swift (SwiftUI View):
  - GeometryReader-based, renders DiskNode children as colored rectangles
  - Each rectangle: colored by file type category (Documents = blue, Media = purple, Apps = orange, Other = gray, System = red)
  - Rectangle shows name + size label if large enough to fit text
  - Click on a directory rectangle: drills into it (updates DiskScannerViewModel.navigationPath)
  - Hover shows tooltip with full path and size
- Create SpaceLensView.swift replacing the placeholder:
  - Top: breadcrumb navigation bar (root > Folder > Subfolder), clicking a crumb navigates back
  - Center: TreemapView for current node's children
  - Bottom bar: total size of current level
  - Loading state: progress bar during scan
  - Empty state: "This folder appears to be empty"
  - "Re-scan" button
- Wire into NavigationSection.spaceLens
```

---

## Phase 3 — Privacy & Apps

### Prompt 18 — Privacy Feature

```
Building on Prompt 17, implement the Privacy feature: browser detection, data clearing, and recently opened files.

Write failing tests first, then implement:

Tests to write first:
- Test that BrowserDetector correctly identifies Safari as always present
- Test that BrowserDetector returns only browsers whose app bundle exists at known paths
- Test that BrowserDataClearer.previewSize(for:browser:) returns an Int64
- Test that PrivacyViewModel starts with all categories checked
- Test that clearing recently opened files removes entries from NSDocumentController recent documents

Implementation:
- Create Browser.swift enum: safari, chrome, firefox, brave, arc, opera, edge, with known bundle IDs and data paths
- Create BrowserDetector.swift:
  - static func installedBrowsers() -> [Browser]
  - Checks existence of each browser's .app bundle at /Applications and ~/Applications
  - Safari always included
- Create BrowserDataClearer.swift:
  - For each browser, maps to specific data file paths (history SQLite DBs, cache directories, cookies files)
  - previewSize(for category: PrivacyCategory, browser: Browser) -> Int64
  - clear(category: PrivacyCategory, browser: Browser) throws
  - Categories: history, downloads, cookies, cache, savedForms
- Create PrivacyViewModel.swift (ObservableObject):
  - Detected browsers list
  - Per-browser, per-category selection state
  - preview() computes sizes
  - clear() clears all selected items
- Create RecentFilesManager.swift:
  - Clears NSDocumentController recent documents
  - Clears system Recent Items via NSAppleScript or defaults write
- Create PrivacyView.swift:
  - Browser list with expand/collapse per browser
  - Checkboxes per category per browser with size labels
  - "Clear" button
  - Confirmation before clearing
- Wire into NavigationSection.privacy
```

---

### Prompt 19 — App Uninstaller

```
Building on Prompt 18, implement the App Uninstaller feature.

Write failing tests first, then implement:

Tests to write first:
- Test that AppDiscovery.installedApps() returns at least one app (Finder)
- Test that AssociatedFileFinder.find(for:) returns paths that include ~/Library/Preferences/\(bundleID)*
- Test that AssociatedFileFinder results are grouped by category (preferences, cache, appSupport, logs, other)
- Test that AppUninstallerViewModel correctly computes total reclaimable size
- Test that AppUninstallerViewModel.uninstall() removes the app bundle and all associated files

Implementation:
- Create AppInfo.swift: struct with name, bundleID, version, bundleURL, icon (NSImage), isAppStore: Bool, associatedFiles: [AssociatedFile]
- Create AppDiscovery.swift:
  - Enumerates /Applications, ~/Applications, /Applications/Utilities
  - Returns [AppInfo] sorted by name
  - Excludes system apps (bundleID prefix com.apple) unless user enables "show system apps" toggle
- Create AssociatedFileFinder.swift:
  - Given a bundleID, searches:
    - ~/Library/Preferences/*.bundleID*
    - ~/Library/Application Support/bundleID/
    - ~/Library/Caches/bundleID/
    - ~/Library/Logs/bundleID/
    - ~/Library/Containers/bundleID/
    - ~/Library/Group Containers/*bundleID*/
    - /Library/LaunchAgents/*bundleID*
    - /Library/LaunchDaemons/*bundleID*
  - Returns [AssociatedFile] with path, size, category
- Create AppUninstallerViewModel.swift (ObservableObject):
  - App list, selection state, associated files per app
  - loadAssociatedFiles(for: AppInfo) async
  - uninstall(apps: [AppInfo]) via FileManager + privileged helper for /Library paths
- Create AppUninstallerView.swift:
  - Searchable app list with icon, name, version, size
  - Selecting an app shows associated files panel on the right
  - Associated files grouped by category with sizes
  - "Uninstall" button — confirmation alert before proceeding
  - Progress during uninstall
- Wire into NavigationSection.appUninstaller
```

---

### Prompt 20 — App Updater

```
Building on Prompt 19, implement the App Updater feature checking both App Store and Sparkle-based apps.

Write failing tests first, then implement:

Tests to write first:
- Test that SparkleUpdateChecker.feedURL(for:) reads SUFeedURL from an app's Info.plist
- Test that SparkleUpdateChecker.parseAppcast(xml:) returns an AppcastItem with version and download URL
- Test that VersionComparator.isNewer(version:than:) correctly compares semantic versions
- Test that AppUpdaterViewModel correctly merges App Store and Sparkle results
- Test that AppUpdaterViewModel shows no update when installed version matches latest

Implementation:
- Create UpdateInfo.swift: struct with appName, installedVersion, latestVersion, source (appStore/sparkle), updateURL
- Create SparkleUpdateChecker.swift:
  - feedURL(for app: AppInfo) -> URL? reads SUFeedURL from app bundle Info.plist
  - fetchUpdate(feedURL: URL) async throws -> UpdateInfo? fetches and parses Sparkle appcast XML
  - Appcast XML parsing: find latest <item> with correct os/arch, extract version and enclosure URL
- Create AppStoreUpdateChecker.swift:
  - Uses iTunes Search API (itunes.apple.com/lookup?bundleId=X) to get latest App Store version
  - Compares against installed version
- Create VersionComparator.swift: isNewer(version: String, than: String) -> Bool using semantic versioning
- Create AppUpdaterViewModel.swift (ObservableObject):
  - Checks all installed apps concurrently (async let / TaskGroup)
  - Merges App Store and Sparkle results into a unified update list
  - update(app: UpdateInfo) opens the Mac App Store or the download URL in the default browser
- Create AppUpdaterView.swift:
  - "Check for Updates" button
  - List of available updates: app icon, name, installed version → latest version, source badge
  - "Update" button per app, "Update All" button
  - Empty state: "All apps are up to date"
- Wire into NavigationSection.appUpdater
```

---

### Prompt 21 — Extensions Manager

```
Building on Prompt 20, implement the Extensions Manager feature.

Write failing tests first, then implement:

Tests to write first:
- Test that SafariExtensionDiscovery.extensions() returns an array (may be empty)
- Test that LaunchAgentDiscovery.userAgents() returns agents from ~/Library/LaunchAgents
- Test that ExtensionItem has required properties: name, path, type, isEnabled
- Test that ExtensionsManagerViewModel groups extensions by type correctly

Implementation:
- Create ExtensionItem.swift: struct with name, path, bundleID (optional), type: ExtensionType, isEnabled: Bool, size: Int64
- ExtensionType enum: safariExtension, chromeExtension, firefoxExtension, mailPlugin, internetPlugin, loginItemFromApp
- Create discovery classes:
  - SafariExtensionDiscovery: reads from ~/Library/Safari/Extensions/ and queries SFSafariExtensionManager state
  - BrowserExtensionDiscovery: enumerates Chrome/Firefox profile extension directories
  - MailPluginDiscovery: scans ~/Library/Mail/Bundles/ and /Library/Mail/Bundles/
  - InternetPluginDiscovery: scans ~/Library/Internet Plug-Ins/ and /Library/Internet Plug-Ins/
  - LoginItemAppDiscovery: reads SMAppService registered items and LaunchAgent plists in ~/Library/LaunchAgents
- Create ExtensionsManagerViewModel.swift (ObservableObject):
  - Runs all discovery classes concurrently
  - Groups results by ExtensionType
  - remove(item: ExtensionItem) via FileManager (user paths) or privileged helper (/Library paths)
- Create ExtensionsManagerView.swift:
  - Grouped list by extension type with section headers
  - Each row: name, source app, size, remove button
  - Confirmation before removal
  - Refresh button
- Wire into NavigationSection.extensions
```

---

## Phase 4 — Optimization & Security

### Prompt 22 — Optimization Feature

```
Building on Prompt 21, implement the Optimization feature: login items, launch agents, RAM flush, and maintenance scripts.

Write failing tests first, then implement:

Tests to write first:
- Test that LoginItemsManager.items() returns items from SMAppService
- Test that LaunchAgentManager.userAgents() correctly parses launchd plist Label keys
- Test that OptimizationViewModel.flushRAM() calls the privileged helper
- Test that OptimizationViewModel.runMaintenanceScripts() calls the privileged helper
- Test that disabling a login item calls SMAppService correctly

Implementation:
- Create LoginItemsManager.swift:
  - items() -> [LoginItem] from SMAppService.loginItems list + legacy Login Items
  - disable(item: LoginItem)
  - remove(item: LoginItem)
- Create LaunchAgentManager.swift:
  - userAgents() -> [LaunchAgent] from ~/Library/LaunchAgents/*.plist
  - systemAgents() -> [LaunchAgent] from /Library/LaunchAgents/*.plist and /Library/LaunchDaemons/*.plist
  - Each LaunchAgent: label, path, isEnabled (loaded status via launchctl list), programPath
  - disable(agent: LaunchAgent) via `launchctl unload`
  - remove(agent: LaunchAgent) via FileManager + privileged helper
- Create RAMManager.swift:
  - flush() calls privileged helper flushInactiveMemory() (which runs `purge`)
- Create MaintenanceScriptRunner.swift:
  - run() calls privileged helper runMaintenanceScripts() (which runs `periodic daily weekly monthly`)
  - Captures output and returns it as a String
- Create OptimizationViewModel.swift (ObservableObject):
  - Loads login items and launch agents
  - flushRAM() async
  - runMaintenanceScripts() async, shows output
- Create OptimizationView.swift:
  - Section: Login Items — list with disable/remove buttons
  - Section: Launch Agents — grouped user/system, with disable/remove buttons
  - Section: RAM — current usage display, "Free Up RAM" button, result shown after flush
  - Section: Maintenance Scripts — "Run Maintenance Scripts" button, output log shown after run
- Wire into NavigationSection.optimization
```

---

### Prompt 23 — ClamAV Integration

```
Building on Prompt 22, implement ClamAV integration for malware scanning.

Write failing tests first, then implement:

Tests to write first:
- Test that ClamAVDetector.isInstalled() returns a Bool
- Test that ClamAVDetector.path() returns a valid path when installed
- Test that ClamAVOutputParser.parse(output:) correctly extracts infected file paths and threat names from sample clamscan output
- Test that ClamAVOutputParser.parse(output:) returns empty array for clean scan output
- Test that DatabaseUpdater.lastUpdateDate() returns a Date or nil

Implementation:
- Create ClamAVDetector.swift:
  - Checks common Homebrew paths for clamscan binary (/opt/homebrew/bin/clamscan, /usr/local/bin/clamscan)
  - isInstalled() -> Bool
  - path() -> URL?
  - version() async -> String?
- Create ClamAVOutputParser.swift:
  - parse(output: String) -> [MalwareThreat]
  - MalwareThreat: struct with filePath: URL, threatName: String
  - Parses lines matching pattern: "/path/to/file: ThreatName FOUND"
- Create DatabaseUpdater.swift:
  - lastUpdateDate() -> Date? reads freshclam.log or CVD file modification date
  - update() async throws runs `freshclam` via Process and reports progress
- Create ClamAVScanner.swift:
  - scan(paths: [URL], progress: @escaping (String) -> Void) async throws -> [MalwareThreat]
  - Runs clamscan with --recursive --infected --no-summary on given paths
  - Streams output line by line for live progress
  - Returns parsed threats
- Create MalwareOnboardingView.swift shown when ClamAV is not installed:
  - Explains that ClamAV is required
  - "Install via Homebrew" button opens Terminal with the brew install clamav command
  - "Check Again" button re-checks installation
```

---

### Prompt 24 — Malware Removal UI

```
Building on Prompt 23, implement the Malware Removal feature view.

Write failing tests first, then implement:

Tests to write first:
- Test that MalwareViewModel starts in idle state
- Test that MalwareViewModel transitions through scanning states correctly
- Test that MalwareViewModel.removeThreats() calls FileManager removal for each threat path
- Test that MalwareViewModel triggers NotificationManager when threats are found
- UI test: open Malware section, tap Scan, verify results appear

Implementation:
- Create MalwareViewModel.swift (ObservableObject):
  - State machine: .idle → .checkingClamAV → .updatingDatabase → .scanning(progress: String) → .results([MalwareThreat]) → .clean → .removing → .done
  - scan() checks ClamAV installed → updates DB if >24h old → scans home directory
  - removeThreats(threats: [MalwareThreat]) via FileManager + privileged helper for protected paths
  - On threats found: call NotificationManager.sendMalwareDetectedNotification
- Create MalwareView.swift replacing the placeholder:
  - ClamAV not installed: show MalwareOnboardingView
  - Idle: "Scan for Malware" button, last scan date, database last updated date, "Update Database" button
  - Scanning: live progress line showing current file being scanned, cancel button
  - Clean: green checkmark, "No threats found", last scan date
  - Results: red warning, list of threats with path and threat name, "Remove All Threats" button
  - Removing: progress indicator
  - Done: confirmation of threats removed
- Wire into NavigationSection.malwareRemoval
```

---

## Phase 5 — Integration & Polish

### Prompt 25 — Smart Scan

```
Building on Prompt 24, implement the Smart Scan feature that orchestrates System Junk, Malware, and Optimization scans.

Write failing tests first, then implement:

Tests to write first:
- Test that SmartScanViewModel runs all three sub-scans when scan() is called
- Test that SmartScanViewModel aggregates results from all three sources
- Test that SmartScanViewModel correctly reports total bytes found
- Test that SmartScanViewModel exposes per-module results
- Test that SmartScanViewModel.clean() delegates to the correct sub-module cleaners
- UI test: open Smart Scan, tap Scan, verify summary appears with results from multiple modules

Implementation:
- Create SmartScanViewModel.swift (ObservableObject):
  - Runs SystemJunkScanner, ClamAVScanner (if installed), and reads login items/launch agents concurrently
  - SmartScanResult: struct with junkResult: ScanResult, threats: [MalwareThreat], optimizationItems: [LoginItem]
  - State machine: .idle → .scanning(phase: String) → .results(SmartScanResult) → .cleaning → .done(summary: SmartScanSummary)
  - clean() delegates: cleans junk via SystemJunkViewModel logic, removes threats, optionally disables login items
- Create SmartScanView.swift replacing the placeholder:
  - Idle: large centered "Scan" button with subtitle "Scans for junk, malware, and optimization opportunities"
  - Scanning: animated circular progress with current phase label ("Scanning System Junk...", "Checking for Malware...", etc.)
  - Results: three summary cards:
    - System Junk card: total size found, "Clean" button
    - Malware card: "No threats" or threat count, "Remove" button (hidden if ClamAV not installed)
    - Optimization card: login item count, "Review" button
  - Tapping each card's action performs that module's clean/action inline
  - Done: "X.X GB freed, X threats removed" summary
- Wire into NavigationSection.smartScan as the default landing view
```

---

### Prompt 26 — Exclusions Wired to All Scanners

```
Building on Prompt 25, wire the ExclusionsStore to every scanner so that excluded paths are respected everywhere.

Write failing tests first, then implement:

Tests to write first:
- Test that SystemJunkScanner skips files inside an excluded path
- Test that LargeOldFilesScanner skips files inside an excluded path
- Test that DiskScanner skips excluded paths in the tree
- Test that BrowserDataClearer skips browsers whose data path is excluded
- Test that AssociatedFileFinder skips excluded paths when building associated file list

Implementation:
- Ensure ExclusionsStore is injected into (or accessible by) every scanner:
  - SystemJunkScanner
  - LargeOldFilesScanner
  - DiskScanner
  - PrivacyViewModel / BrowserDataClearer
  - AssociatedFileFinder
- Update FileScanner.scan(paths:excluding:) to accept the current ExclusionsStore.exclusions as the excluding parameter — this is the single point of exclusion for file-based scanners
- Add integration tests that create a file inside an excluded temp directory, run each scanner, and assert the file does not appear in results
- Update PreferencesView Exclusions tab to show a file picker that adds real paths to ExclusionsStore
- Add a right-click "Add to Exclusions" context menu item in LargeOldFilesView and AppUninstallerView
```

---

### Prompt 27 — Final Polish, Error Handling & E2E Tests

```
Building on Prompt 26, add final polish, comprehensive error handling, and end-to-end UI tests.

Write E2E tests first, then implement fixes:

E2E tests to write (XCUITest):
- Launch app → verify sidebar shows all 11 sections
- Navigate to Health Monitor → verify at least 3 stat cards are visible
- Navigate to System Junk → tap Scan → wait for preview → verify category list appears → tap Cancel
- Navigate to Large & Old Files → tap Scan → verify table appears (or empty state)
- Navigate to Space Lens → verify treemap loads for home directory
- Navigate to App Uninstaller → verify app list loads with at least 5 apps
- Navigate to Optimization → verify Login Items section is visible
- Open Preferences → verify all 4 tabs are accessible
- Toggle Menu Bar off in Preferences → verify menu bar icon disappears

Error handling to add throughout:
- Every async operation that can fail shows a user-facing alert with a clear message (not raw error descriptions)
- Privileged helper connection failure: show alert with "VaderCleaner Helper is not responding. Try restarting the app."
- Full Disk Access not granted: scanners that require FDA show an inline prompt instead of empty results
- ClamAV not found: Malware section shows onboarding (already done in Prompt 24, verify wired correctly)
- Network unavailable for App Updater: show "Could not check for updates. Check your internet connection."

Polish:
- Add app icon (use SF Symbol "sparkles" as placeholder rendered to PNG at required sizes)
- Add About window (SwiftUI Settings scene or NSApplication.orderFrontStandardAboutPanel)
- Ensure every view has an appropriate empty state with helpful copy
- Verify all 11 sidebar sections navigate correctly with no placeholder views remaining
- Run full test suite and fix any failures
```

---

## Summary

| Prompt | Feature | Phase |
|--------|---------|-------|
| 1 | Xcode project + test harness | Foundation |
| 2 | App shell + sidebar navigation | Foundation |
| 3 | Privileged helper tool (XPC) | Foundation |
| 4 | Full Disk Access detection + onboarding | Foundation |
| 5 | Menu bar extra | Foundation |
| 6 | Preferences model + window | Foundation |
| 7 | Launch at login | Foundation |
| 8 | System stats service | Health |
| 9 | Health Monitor UI | Health |
| 10 | Menu bar live stats | Health |
| 11 | Notification system | Health |
| 12 | File scanner infrastructure | Cleaning |
| 13 | System Junk scanner | Cleaning |
| 14 | System Junk UI + deletion | Cleaning |
| 15 | Large & Old Files | Cleaning |
| 16 | Space Lens disk scanner | Cleaning |
| 17 | Space Lens treemap UI | Cleaning |
| 18 | Privacy feature | Privacy & Apps |
| 19 | App Uninstaller | Privacy & Apps |
| 20 | App Updater | Privacy & Apps |
| 21 | Extensions Manager | Privacy & Apps |
| 22 | Optimization feature | Optimization & Security |
| 23 | ClamAV integration | Optimization & Security |
| 24 | Malware Removal UI | Optimization & Security |
| 25 | Smart Scan | Integration |
| 26 | Exclusions wired to all scanners | Integration |
| 27 | Final polish + E2E tests | Integration |

---

## Phase 6 — Scan-Centric Redesign

This phase is a UI redesign (not part of the original 27-prompt build above, which is complete). Goal: a consistent per-section landing screen — accent-tinted hero, title, one-line description, and a descriptive sub-feature list — plus a single persistent floating **Scan** button, for the **six scan-capable sections**: Smart Scan, System Junk, Large & Old Files, Space Lens, Malware Removal, Optimization. The other five sections (Health Monitor, Privacy, Extensions, App Uninstaller, App Updater) are unchanged.

### Decisions (locked)

- **Brand stays crimson.** The `.vaderShell()` window gradient is unchanged. Per-section accent color applies *only* to intro-screen elements (hero symbol, sub-feature icons, Scan button) — not the whole window.
- **Hero baseline = SF Symbols.** Each section uses a large tinted SF Symbol as its hero now, with an optional `heroAssetName` field so designer art can swap in later with no code change.
- **No view-model rewrites.** The six view models keep their existing `Phase` enums and scan entrypoints. A thin `ScanCoordinating` protocol is added via extensions that map each native phase to a coarse `ScanPresentation` and route `beginScan()` to the existing entrypoint (per the global CLAUDE.md "don't rewrite without permission" rule).
- **Replace, don't overlay.** When a section's coordinator reports `.intro`, ContentView renders the generic `SectionIntroView` *instead of* that section's detail view. Detail views render only for `.working`/`.results`. This avoids double UI; Step 7 is then a pure deletion of the now-dead idle code.
- **Smart Scan's three sub-feature rows** are its real orchestrated modules — System Junk, Malware Removal, Optimization — not invented marketing labels.
- Every step is TDD (tests first) and ends with everything wired; no orphaned code.

### Prompt 28 — Step 1/8: SectionPresentation model + isScannable ([#84](https://github.com/jayvicsanantonio/VaderCleaner/issues/84))

Foundation data model, no UI. Add `NavigationSection.isScannable` (true for exactly the six scannable sections) and a `SectionPresentation` struct (hero symbol, optional asset name, accent `Color`, tagline, `[SectionFeature]`) with a `for(_:)` factory. Pin Smart Scan's features to System Junk / Malware Removal / Optimization.

```text
Building on the existing VaderCleaner codebase, add a section-presentation model. TDD: write the tests first.

1. Add `var isScannable: Bool` to NavigationSection. True ONLY for: .smartScan, .systemJunk, .largeOldFiles, .spaceLens, .malwareRemoval, .optimization.
2. Create VaderCleaner/SectionPresentation.swift with `struct SectionPresentation` (heroSymbol, heroAssetName: String?, accent: Color, tagline, features: [SectionFeature]) and `struct SectionFeature { symbol; title }`, plus `static func for(_ section: NavigationSection) -> SectionPresentation?` (nil for non-scannable).
3. Pin per-section content (contract — tests assert it). Smart Scan features = System Junk/"trash", Malware Removal/"shield.lefthalf.filled", Optimization/"gauge.with.needle". Accents: SmartScan crimson, SystemJunk green, LargeOldFiles teal, SpaceLens indigo, Malware crimson, Optimization orange. All user-facing strings via String(localized:).
4. Tests (VaderCleanerTests/SectionPresentationTests.swift): isScannable true for exactly the six; for(:) non-nil for the six and nil otherwise; Smart Scan features are the three modules in order; every scannable section has non-empty features with non-empty symbols/titles. Mirror NavigationSectionTests style.

Add files to the Xcode project (project.yml is XcodeGen-driven). 2-line header comments. Full suite green.
```

### Prompt 29 — Step 2/8: ScanPresentation enum + ScanCoordinating protocol ([#85](https://github.com/jayvicsanantonio/VaderCleaner/issues/85))

The coarse abstraction ContentView uses to choose "generic intro + Scan" vs "section's own detail view". Plain protocol, no associated types, no type erasure.

```text
Building on Step 1, add VaderCleaner/ScanCoordinating.swift:
- enum ScanPresentation: Equatable { case intro, working, results }  (.intro → generic intro + floating Scan; .working → scan/load in progress; .results → section's own detail UI renders)
- protocol ScanCoordinating: ObservableObject { var scanPresentation: ScanPresentation { get }; func beginScan() }  — plain protocol, no associated types.
Tests (VaderCleanerTests/ScanCoordinatingTests.swift): a private FakeCoordinator; assert ScanPresentation Equatable; assert beginScan() flips a flag and a presentation change is observable via objectWillChange. No view model modified this step. 2-line headers; add to project; full suite green.
```

### Prompt 30 — Step 3/8: Conform the 6 view models to ScanCoordinating ([#86](https://github.com/jayvicsanantonio/VaderCleaner/issues/86))

Extensions only — map each native `Phase` to `ScanPresentation`, route `beginScan()` to the existing entrypoint. Space Lens default root = home dir. Optimization `beginScan()` = its load path (semantic stretch, commented).

```text
Building on Step 2, add `extension <VM>: ScanCoordinating` for all six VMs (do not alter their methods or Phase enums):
- SmartScan: .idle→.intro; .scanning→.working; .results/.cleaning/.done/.failed→.results; beginScan→Task{await scan()}.
- SystemJunk: .idle→.intro; .scanning/.cleaning→.working; .preview/.complete/.failed→.results; beginScan→Task{await scan()}.
- LargeOldFiles: .idle→.intro; .scanning→.working; .results/.empty/.failed→.results; beginScan→Task{await scan()}.
- DiskScanner: .idle→.intro; .scanning→.working; .ready/.error→.results; beginScan→Task{await startScan(root: FileManager.default.homeDirectoryForCurrentUser)} (comment: default Space Lens root).
- Malware: .idle→.intro; .checkingClamAV/.updatingDatabase/.scanning/.removing→.working; .needsInstall/.results/.clean/.done/.failed→.results; beginScan→Task{await scan()} (.needsInstall→.results so MalwareView shows install onboarding).
- Optimization: .idle→.intro; .loading→.working; .ready/.working/.failed→.results; beginScan→its existing on-appear load path (comment: "scan"=="load", semantic stretch).
Tests (VaderCleanerTests/ScanCoordinatingConformanceTests.swift): per VM, construct with injected fakes (follow each existing *ViewModelTests), drive phases, assert the coarse value at each; assert beginScan() leaves .intro. 2-line headers; add new files to project; full suite green.
```

### Prompt 31 — Step 4/8: Extract reusable FloatingScanButton ([#87](https://github.com/jayvicsanantonio/VaderCleaner/issues/87))

Relocate (do not reimplement) the existing private `CircularActionButton` + `PressableCircleButtonStyle` from `SmartScanViewSubviews.swift` into a shared, accent-parameterized `FloatingScanButton`. SmartScan must look/behave identically.

```text
Building on Step 1, move CircularActionButton and PressableCircleButtonStyle out of SmartScanViewSubviews.swift into VaderCleaner/FloatingScanButton.swift as `struct FloatingScanButton: View { title; accent: Color; accessibilityIdentifier; action }`. Keep the crimson interactive-glass disc + press animation; tint from accent (default crimson). Update SmartScan call sites to use it with accent crimson and existing titles/actions — no visual/behavioral change to SmartScan. Tests (VaderCleanerTests/FloatingScanButtonTests.swift): verify the a11y id is exposed and action fires (use the repo's existing view-test approach; else a small @MainActor harness). 2-line header; add to project; SmartScan UI tests + full suite green.
```

### Prompt 32 — Step 5/8: SectionIntroView ([#88](https://github.com/jayvicsanantonio/VaderCleaner/issues/88))

The reusable landing screen: accent hero + title + tagline + descriptive feature rows. No Scan button inside (ContentView owns it so it can float over the window edge).

```text
Building on Steps 1 and 4, create VaderCleaner/SectionIntroView.swift. `struct SectionIntroView: View { presentation: SectionPresentation; title: String }`: large accent-tinted hero (asset if heroAssetName else SF Symbol ~120pt) with a soft accent bloom (reuse SmartScanIdleState's bloom); large bold title; secondary tagline (max ~420 width, multiline); vertical list of feature rows (accent icon + title, no checkboxes/actions). Hero-left / text-right at wide widths, stacks when narrow. Do NOT render a Scan button. Accessibility: root id `section.intro`, per-feature id `section.intro.feature.<index>`, accessible title/tagline. Tests (VaderCleanerTests/SectionIntroViewTests.swift): for each scannable presentation, view builds, expected a11y ids present, feature count matches. 2-line header; add to project; full suite green; no other view touched.
```

### Prompt 33 — Step 6/8: Wire intro + floating Scan into ContentView ([#89](https://github.com/jayvicsanantonio/VaderCleaner/issues/89))

**Everything wired end-to-end.** Replace (don't overlay): scannable section at `.intro` → `SectionIntroView`; `.working`/`.results` → existing detail view. One floating Scan overlay on the outer HStack. Migrate UI-test identifiers to `section.<id>.scan`.

```text
Building on Steps 3–5, in ContentView.swift:
1. In detailView(for:): if section.isScannable, read its VM as ScanCoordinating. If coordinator.scanPresentation == .intro return SectionIntroView(presentation: SectionPresentation.for(section)!, title: section.title); else return the existing detail view unchanged. Non-scannable sections unchanged.
2. Add a FloatingScanButton as `.overlay(alignment: .bottom)` on the OUTER HStack (not inside NavigationStack) with negative bottom padding (disc half outside the edge + glow, per screenshots). Show ONLY when selectedSection.isScannable AND its scanPresentation == .intro; accent = SectionPresentation.for(selectedSection)?.accent ?? .vaderCrimson; id `section.<suffix>.scan`; action = coordinator.beginScan().
3. Detail views remain the source of truth for working/results — no duplication.
4. Update affected UI tests: navigate → assert `section.intro` → tap `section.<id>.scan` → assert working/results UI. Repoint every old idle-scan id (system-junk.scan, large-old-files.scan, SmartScan idle scan, malware/optimization/space-lens scan triggers) to `section.<id>.scan`. Do NOT delete dead idle code yet (Step 7).
Match ContentView style. Full unit + UI suite green.
```

### Prompt 34 — Step 7/8: Retire per-section bespoke idle states ([#90](https://github.com/jayvicsanantonio/VaderCleaner/issues/90))

Pure deletion — remove the now-unreachable `.idle`/landing UI from the six scannable section views and their idle-only subviews. No behavior change.

```text
Building on Step 6, delete the now-unreachable per-section idle/landing UI: SmartScanIdleState, SystemJunkView.idleState, and the equivalent in LargeOldFilesView/SpaceLensView/MalwareView/OptimizationView. The detail view's switch should have no idle UI arm (EmptyView/no-op if the enum still has .idle, since ContentView never routes there at .intro). Do NOT change Phase enums or working/results/done/failed branches. Update/delete only tests that asserted the deleted idle UI; keep working/results coverage. Preserve still-accurate comments (repo rule). 2-line headers stay. Full unit + UI suite green, no regression vs end of Step 6.
```

### Prompt 35 — Step 8/8: Transitions, accessibility, E2E, README ([#91](https://github.com/jayvicsanantonio/VaderCleaner/issues/91))

Polish and end-to-end verification.

```text
Building on Step 7: (1) crossfade intro→working→results reusing SmartScanView's phaseTransitionID/.transition(.opacity)/.animation(.smooth) pattern; floating Scan fades (not pops) when leaving .intro. (2) Accessibility: VoiceOver labels for hero/title/tagline/each feature and "Scan <Section>" on the button; Dynamic Type must scroll/stack, not clip. (3) E2E (XCUITest) for each of the six scannable sections: launch → select → assert section.intro with right title → tap section.<id>.scan → assert working then results/detail (or valid empty/needs-install for Malware); plus assert a non-scannable section (Health Monitor) has NO floating Scan and is unchanged. (4) README.md: document the unified landing + floating Scan; keep ToC anchors stable. Run full unit + UI suite; fix any flake.
```

### Phase 6 Summary

| Prompt | Step | Feature | Issue |
|--------|------|---------|-------|
| 28 | 1/8 | SectionPresentation model + isScannable | [#84](https://github.com/jayvicsanantonio/VaderCleaner/issues/84) |
| 29 | 2/8 | ScanPresentation + ScanCoordinating protocol | [#85](https://github.com/jayvicsanantonio/VaderCleaner/issues/85) |
| 30 | 3/8 | Conform 6 view models (extensions) | [#86](https://github.com/jayvicsanantonio/VaderCleaner/issues/86) |
| 31 | 4/8 | Extract FloatingScanButton | [#87](https://github.com/jayvicsanantonio/VaderCleaner/issues/87) |
| 32 | 5/8 | SectionIntroView | [#88](https://github.com/jayvicsanantonio/VaderCleaner/issues/88) |
| 33 | 6/8 | Wire into ContentView (everything wired) | [#89](https://github.com/jayvicsanantonio/VaderCleaner/issues/89) |
| 34 | 7/8 | Retire bespoke idle states | [#90](https://github.com/jayvicsanantonio/VaderCleaner/issues/90) |
| 35 | 8/8 | Transitions, a11y, E2E, README | [#91](https://github.com/jayvicsanantonio/VaderCleaner/issues/91) |
