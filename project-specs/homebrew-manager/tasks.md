# Implementation Plan

Each task is test-first: write the failing test, then the minimal code to pass, then refactor. Tasks build incrementally with no orphaned code — every type is consumed by a later task, ending in the wired-up view. Files are registered via XcodeGen (`xcodegen generate`), never hand-edited pbxproj.

- [x] 1. Define core data models
  - Create `VaderCleaner/BrewPackage.swift` with `BrewPackageKind`, `BrewPackage`, `BrewOutdatedItem`, `UninstallConfirmation`, and `UpgradeSelection` value types (all `Sendable`, `Identifiable`/`Hashable` where specified in the design).
  - Write `VaderCleanerTests/BrewModelTests.swift` asserting `id` composition (name+kind disambiguation), `UninstallConfirmation.hasBlockingDependents`, and Equatable/Hashable behavior.
  - Run `xcodegen generate` to register the new files.
  - _Requirements: 3.1, 4.2, 6.2_

- [x] 2. Implement Homebrew output parsing
  - [x] 2.1 Parse list, leaves, and uses output
    - Create `VaderCleaner/BrewOutputParser.swift` with `parseListVersions(_:kind:)`, `parseLeaves(_:)`, `parseUses(_:)`.
    - Write `VaderCleanerTests/BrewOutputParserListTests.swift` with fixtures: single/multi-version list lines, empty output, `leaves` set, `uses` with and without dependents.
    - _Requirements: 3.1, 3.2, 6.1, 6.4_
  - [x] 2.2 Parse outdated JSON (`--json=v2`)
    - Add `parseOutdatedJSON(_:)` decoding the v2 schema (`formulae[]`, `casks[]`, each with name, installed_versions, current_version, pinned) into `[BrewOutdatedItem]`.
    - Write `VaderCleanerTests/BrewOutdatedParserTests.swift` with fixtures: formulae-only, casks-only, mixed, pinned flag set, empty, malformed JSON (throws).
    - Add JSON fixture files under `VaderCleanerTests/Fixtures/brew/`.
    - _Requirements: 4.1, 4.2, 4.3_
  - [x] 2.3 Parse cleanup dry-run and autoremove output
    - Add `parseCleanupDryRun(_:) -> Int64?` (returns the reclaimable byte total, `nil` when absent) and `parseAutoremove(_:) -> [String]`.
    - Write `VaderCleanerTests/BrewCleanupParserTests.swift`: byte total present, "Nothing to do", unparseable → `nil`, autoremove removed-names list.
    - _Requirements: 7.1, 7.3, 7.5_

- [x] 3. Implement Homebrew executable location
  - Create `VaderCleaner/BrewLocator.swift` with `BrewLocating` protocol and `DefaultBrewLocator` (injectable candidate paths, Apple-silicon prefix first, executable-file check).
  - Write `VaderCleanerTests/BrewLocatorTests.swift` with injected temp-dir candidates: Apple-silicon-only, Intel-only, both (first wins), none, present-but-non-executable.
  - _Requirements: 1.1, 1.2, 10.4_

- [x] 4. Add stderr-capturing streamed process support
  - [x] 4.1 Extend the process streamer to capture stderr
    - Modify `VaderCleaner/ProcessLineStreamer.swift` to add a variant (or parameter) that merges/captures stderr rather than routing it to `/dev/null`, preserving the existing cancellation (SIGTERM) and line-buffering behavior. Do not change existing call sites' behavior.
    - Update/extend `VaderCleanerTests/ProcessLineStreamerTests.swift` (or create it) to assert stderr lines are delivered and cancellation still SIGTERMs a long-running stub.
    - _Requirements: 9.1, 9.2, 9.4_

- [x] 5. Implement the brew execution seam
  - [x] 5.1 Define the BrewRunning protocol and result type
    - Create `VaderCleaner/BrewRunning.swift` with `BrewRunning` protocol (`runCapturing`, `runStreaming`) and `BrewResult`.
    - _Requirements: 2.1, 9.1, 10.1_
  - [x] 5.2 Implement DefaultBrewRunner
    - Create `VaderCleaner/DefaultBrewRunner.swift`: derives environment from `ProcessInfo.processInfo.environment` (adds `HOMEBREW_NO_AUTO_UPDATE`/`HOMEBREW_NO_ENV_HINTS`), sets child `standardInput = FileHandle.nullDevice`, implements buffered capture and delegates `runStreaming` to the stderr-capturing streamer from task 4.
    - Write `VaderCleanerTests/DefaultBrewRunnerTests.swift` using a temp fake-`brew` shell script: asserts `HOME`/`PATH` passthrough, stdin closed (stub reading stdin sees EOF, exits non-zero, does not hang), buffered stdout capture, streamed line ordering + termination status, and SIGTERM-on-cancel.
    - _Requirements: 2.1, 2.2, 8.1, 9.1, 9.2_

- [x] 6. Implement the view model state machine
  - [x] 6.1 Inventory load and availability gating
    - Create `VaderCleaner/HomebrewViewModel.swift` (`@MainActor @Observable`) with the `Phase`/`Operation` enums and `load()`: locate brew → `.notInstalled` when absent, else run list/leaves off the main actor and populate `inventory`; `.failed` when brew is present but fails.
    - Write `VaderCleanerTests/HomebrewViewModelLoadTests.swift` with stubbed seams: not-installed, empty inventory, ready with formulae+casks+leaf flags, brew-fails → `.failed`.
    - _Requirements: 1.2, 1.4, 3.1, 3.2, 3.4, 3.5, 10.1, 10.2_
  - [x] 6.2 Update check and outdated dashboard
    - Add `checkUpdates()`: run `brew update` then `outdated --json=v2`, parse, populate `outdated`, mark pinned, expose the available-update count; still report outdated on `brew update` failure.
    - Extend tests: checking→outdated with counts, pinned marked, `brew update` offline still lists outdated.
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_
  - [x] 6.3 Upgrade (all / selected)
    - Add `upgrade(_:)`: `.all` excludes pinned before invoking `brew upgrade`; `.some` upgrades exactly the selected; stream lines into `liveLog`; refresh dashboard on completion; report a failed package and continue.
    - Extend tests: upgrade-all excludes pinned, upgrade-selected, per-package failure continues, dashboard refreshed.
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_
  - [x] 6.4 Dependency-aware uninstall
    - Add `requestUninstall(_:)` (runs `uses --installed`, builds `UninstallConfirmation`, sets `pendingUninstall`) and `confirmUninstall()` (runs `brew uninstall`, refreshes inventory).
    - Extend tests: target with dependents → confirmation gate populated; confirm → uninstall runs → inventory refreshed; leaf target has no blocking dependents.
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6_
  - [x] 6.5 Cleanup, autoremove, and reclaim preview
    - Add `previewCleanup()` (`cleanup -n` → `reclaimablePreview`, `nil`→unavailable), `runCleanup()`, `runAutoremove()`, and the post-uninstall continuation offering both.
    - Extend tests: preview populates bytes, unparseable → unavailable, cleanup runs, autoremove reports removed names, post-uninstall continuation offered.
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_
  - [x] 6.6 Cancellation, concurrency guard, and sudo/stall routing
    - Add `cancelActiveOperation()` (SIGTERM via runner, return to `.ready`), the single-active-operation guard, and the no-output stall watchdog that flips to a "run in Terminal: `<command>`" message.
    - Extend tests: cancel returns to `.ready`, second mutating op blocked while running, sudo/stall → requires-Terminal message with exact command.
    - _Requirements: 8.1, 8.2, 8.3, 9.2, 9.3, 9.4_

- [x] 7. Wire the live factory
  - Add `HomebrewViewModel.live()` composing `DefaultBrewLocator` + `DefaultBrewRunner` + `BrewOutputParser`, matching the `AppUpdaterViewModel.live()` pattern.
  - Write a smoke test asserting `.live()` constructs without touching real `brew` (locator returns nil in the test environment → `.notInstalled` on load, or inject a stub locator).
  - _Requirements: 2.1, 10.1_

- [x] 8. Build the manager view
  - [x] 8.1 Core view and states
    - Create `VaderCleaner/HomebrewManagerView.swift` binding to `HomebrewViewModel.phase`: not-installed state (install link, no action controls), empty-inventory state, glance summary (installed / updates / reclaimable counts), inventory list (formula vs cask, leaf badges) reusing `ManagerChrome`/`managerRowCard()`.
    - _Requirements: 1.2, 1.3, 3.3, 6.4, 11.3_
  - [x] 8.2 Operation surfaces
    - Add the outdated dashboard with upgrade-all/selected controls, the streamed-progress overlay with a working Cancel button, the uninstall confirmation sheet listing dependents, and the cleanup/autoremove reclaim controls. Give the refresh entry point a stable accessibility identifier per the app's `section.*` convention.
    - _Requirements: 5.1, 5.2, 6.2, 7.1, 9.2, 11.2_

- [x] 9. Integrate into the Applications section
  - Add a `homebrew` case to `ApplicationsManagerView.Destination` and a Homebrew entry on the Applications dashboard that routes to `HomebrewManagerView`.
  - Update the relevant navigation/destination tests to cover the new case and its accessibility identifier.
  - Run `xcodegen generate`.
  - _Requirements: 11.1, 11.2_

- [x] 10. End-to-end UI test
  - Create `VaderCleanerUITests/HomebrewManagerUITests.swift` driving Applications → Homebrew against a `BrewRunning` stub wired through a launch-argument seam: not-installed hides action controls, glance counts render, outdated list renders, upgrade progress overlay + Cancel appears, uninstall confirmation sheet lists dependents. (Compiles in CI; execution handed to the user per the repo's UITest-runner constraint.)
  - _Requirements: 1.2, 4.4, 5.3, 6.2, 11.2, 11.3_
