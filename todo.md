# VaderCleaner — Todo

## Status Legend
- [ ] Not started
- [~] In progress
- [x] Complete

---

## Phase 0 — Foundation

- [ ] **Prompt 1** — Xcode project + XCTest + XCUITest targets + TestHelpers
- [ ] **Prompt 2** — App shell + NavigationSection enum + sidebar navigation (11 sections)
- [ ] **Prompt 3** — Privileged XPC helper tool (VaderCleanerHelper target + HelperConnectionManager)
- [ ] **Prompt 4** — Full Disk Access detection + onboarding sheet
- [ ] **Prompt 5** — Menu bar extra (basic, placeholder stats)
- [ ] **Prompt 6** — PreferencesStore + ExclusionsStore + Preferences window (4 tabs)
- [ ] **Prompt 7** — Launch at login (SMAppService, wired to Preferences toggle)

## Phase 1 — System Stats & Health Monitor

- [ ] **Prompt 8** — SystemStatsService (CPU, RAM, disk, battery, SMART, FileVault)
- [ ] **Prompt 9** — Health Monitor UI (5 stat cards + FileVault row)
- [ ] **Prompt 10** — Menu bar live stats (wired to SystemStatsService)
- [ ] **Prompt 11** — Notification system (4 notification types, threshold monitoring, cooldown)

## Phase 2 — File Cleaning

- [ ] **Prompt 12** — File scanner infrastructure (FileScanner, ScanCategory, ScanResult)
- [ ] **Prompt 13** — System Junk scanner (all 8 categories)
- [ ] **Prompt 14** — System Junk UI + deletion (scan → preview → clean flow)
- [ ] **Prompt 15** — Large & Old Files scanner + UI
- [ ] **Prompt 16** — Space Lens disk scanner (DiskNode tree + DiskScanner)
- [ ] **Prompt 17** — Space Lens treemap UI (squarified treemap + drill-down)

## Phase 3 — Privacy & Apps

- [ ] **Prompt 18** — Privacy feature (browser detection + data clearing + recent files)
- [ ] **Prompt 19** — App Uninstaller (discovery + associated files + deletion)
- [ ] **Prompt 20** — App Updater (App Store + Sparkle)
- [ ] **Prompt 21** — Extensions Manager (Safari, browser, Mail, internet plugins, login items)

## Phase 4 — Optimization & Security

- [ ] **Prompt 22** — Optimization feature (login items, launch agents, RAM flush, maintenance scripts)
- [ ] **Prompt 23** — ClamAV integration (detection, DB update, scanning, output parsing)
- [ ] **Prompt 24** — Malware Removal UI (scan → results → remove flow)

## Phase 5 — Integration & Polish

- [ ] **Prompt 25** — Smart Scan (orchestrates junk + malware + optimization)
- [ ] **Prompt 26** — Exclusions wired to all scanners
- [ ] **Prompt 27** — Final polish, error handling, E2E tests, app icon, About window
