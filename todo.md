# VaderCleaner — Todo

## Status Legend
- [ ] Not started
- [~] In progress
- [x] Complete

---

## Phase 0 — Foundation

- [x] **Prompt 1** — Xcode project + XCTest + XCUITest targets + TestHelpers
- [x] **Prompt 2** — App shell + NavigationSection enum + sidebar navigation (11 sections)
- [x] **Prompt 3** — Privileged XPC helper tool (VaderCleanerHelper target + HelperConnectionManager)
- [x] **Prompt 4** — Full Disk Access detection + onboarding sheet
- [x] **Prompt 5** — Menu bar extra (basic, placeholder stats)
- [x] **Prompt 6** — PreferencesStore + ExclusionsStore + Preferences window (4 tabs)
- [x] **Prompt 7** — Launch at login (SMAppService, wired to Preferences toggle)

## Phase 1 — System Stats & Health Monitor

- [x] **Prompt 8** — SystemStatsService (CPU, RAM, disk, battery, SMART, FileVault)
- [x] **Prompt 9** — Health Monitor UI (5 stat cards + FileVault row)
- [x] **Prompt 10** — Menu bar live stats (wired to SystemStatsService)
- [x] **Prompt 11** — Notification system (4 notification types, threshold monitoring, cooldown)

## Phase 2 — File Cleaning

- [x] **Prompt 12** — File scanner infrastructure (FileScanner, ScanCategory, ScanResult)
- [x] **Prompt 13** — System Junk scanner (all 8 categories)
- [x] **Prompt 14** — System Junk UI + deletion (scan → preview → clean flow)
- [x] **Prompt 15** — Large & Old Files scanner + UI
- [x] **Prompt 16** — Space Lens disk scanner (DiskNode tree + DiskScanner)
- [x] **Prompt 17** — Space Lens treemap UI (squarified treemap + drill-down)

## Phase 3 — Privacy & Apps

- [x] **Prompt 18** — Privacy feature (browser detection + data clearing + recent files)
- [x] **Prompt 19** — App Uninstaller (discovery + associated files + deletion)
- [x] **Prompt 20** — App Updater (App Store + Sparkle)
- [x] **Prompt 21** — Extensions Manager (Safari, browser, Mail, internet plugins, login items)

## Phase 4 — Optimization & Security

- [x] **Prompt 22** — Optimization feature (login items, launch agents, RAM flush, maintenance scripts)
- [x] **Prompt 23** — ClamAV integration (detection, DB update, scanning, output parsing)
- [x] **Prompt 24** — Malware Removal UI (scan → results → remove flow)

## Phase 5 — Integration & Polish

- [x] **Prompt 25** — Smart Scan (orchestrates junk + malware + optimization)
- [x] **Prompt 26** — Exclusions wired to all scanners
- [x] **Prompt 27** — Final polish, error handling, E2E tests, app icon, About window

## Phase 6 — Scan-Centric Redesign

- [x] **Prompt 28** — Step 1/8: SectionPresentation model + `isScannable` ([#84](https://github.com/jayvicsanantonio/VaderCleaner/issues/84))
- [x] **Prompt 29** — Step 2/8: ScanPresentation enum + ScanCoordinating protocol ([#85](https://github.com/jayvicsanantonio/VaderCleaner/issues/85))
- [x] **Prompt 30** — Step 3/8: Conform the 6 scannable view models (extensions) ([#86](https://github.com/jayvicsanantonio/VaderCleaner/issues/86))
- [x] **Prompt 31** — Step 4/8: Extract reusable FloatingScanButton ([#87](https://github.com/jayvicsanantonio/VaderCleaner/issues/87))
- [x] **Prompt 32** — Step 5/8: SectionIntroView (hero + description + sub-features) ([#88](https://github.com/jayvicsanantonio/VaderCleaner/issues/88))
- [ ] **Prompt 33** — Step 6/8: Wire intro + floating Scan into ContentView ([#89](https://github.com/jayvicsanantonio/VaderCleaner/issues/89))
- [ ] **Prompt 34** — Step 7/8: Retire per-section bespoke idle states ([#90](https://github.com/jayvicsanantonio/VaderCleaner/issues/90))
- [ ] **Prompt 35** — Step 8/8: Transitions, accessibility, E2E, README ([#91](https://github.com/jayvicsanantonio/VaderCleaner/issues/91))
