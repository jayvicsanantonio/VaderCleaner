# VaderCleaner

**A native macOS app that cleans junk, frees space, finds malware, protects your privacy, and keeps an eye on your Mac's health — all in one place.**

VaderCleaner is a Mac maintenance toolkit. It helps you reclaim disk space, tidy up the clutter that builds up over time, remove apps completely, keep your other apps up to date, and watch your system's vital signs — without sending anything off your machine.

---

## Table of Contents

- [Who it's for](#who-its-for)
- [What you need](#what-you-need)
- [Features](#features)
  - [Smart Scan](#smart-scan)
  - [System Junk](#system-junk)
  - [Large & Old Files](#large-old-files)
  - [Space Lens](#space-lens)
  - [Malware Removal](#malware-removal)
  - [Privacy](#privacy)
  - [Extensions](#extensions)
  - [App Uninstaller](#app-uninstaller)
  - [App Updater](#app-updater)
  - [Optimization](#optimization)
  - [Health Monitor](#health-monitor)
  - [Menu Bar quick view](#menu-bar-quick-view)
  - [Notifications](#notifications)
  - [Preferences](#preferences)
- [Permissions explained (in plain English)](#permissions-explained-in-plain-english)
- [Your data & safety](#your-data--safety)
- [For developers: running it locally](#for-developers-running-it-locally)
- [License](#license)

---

## Who it's for

Anyone with a Mac that feels full, slow, or cluttered. You don't need to be technical to use VaderCleaner — every tool shows you exactly what it found, lets you decide what to remove, and never deletes anything without your confirmation.

## What you need

- A Mac running **macOS 26 or later**
- About a minute to grant **Full Disk Access** the first time (the app walks you through it — see [Permissions explained](#permissions-explained-in-plain-english))
- *(Optional)* **ClamAV** installed if you want to use the malware scanner — see the [Malware Removal](#malware-removal) section

---

## Features

VaderCleaner is organized into eleven tools, plus a menu bar quick view, notifications, and preferences. Pick a tool from the sidebar on the left.

Every tool that runs a scan — Smart Scan, System Junk, Large & Old Files, Space Lens, Malware Removal, and Optimization — opens to the same kind of landing screen: a large illustration, a one-line description of what the tool does, and a short list of what the upcoming scan will cover. Nothing runs until you press the round **Scan** button that floats at the bottom of the window. While the scan works the landing crossfades into its progress and results, and the Scan button fades away. The tools that show live information instead of scanning (Health Monitor, Privacy, Extensions, App Uninstaller, App Updater) keep their own layout and have no Scan button.

<a id="smart-scan"></a>

### ✨ Smart Scan

**The one-button checkup.** Smart Scan runs the three most important checks at once — junk files, malware, and startup items — and shows you a single summary of everything it found. If you only do one thing, do this.

- Finds reclaimable junk, scans for malware (if ClamAV is installed), and lists apps that launch automatically when you log in.
- Shows total space you can free and how many threats were found.
- You review the findings and confirm before anything is removed.
- If the malware scanner isn't installed, Smart Scan still works — it just marks the malware result as "not checked" instead of failing.

<a id="system-junk"></a>

### 🗑️ System Junk

**Clears the cache, logs, and temporary files that pile up invisibly.** Apps and macOS constantly create throwaway files. Over months this can add up to many gigabytes.

- Scans and groups junk by category (caches, logs, temporary files, and more) so you can see what's safe to clear.
- Every category is pre-selected, with a size next to each — uncheck anything you'd rather keep.
- Shows exactly how much space was freed when it's done.
- Honors your **Exclusions** list, so folders you've marked as off-limits are never touched.

<a id="large-old-files"></a>

### 📄 Large & Old Files

**Finds the big files you forgot about.** Old downloads, huge videos, leftover disk images — the things quietly eating your storage.

- Scans your home folder for files above a size you choose and/or older than a number of days you choose.
- Results appear in a sortable table (by size, date, or name) so the biggest offenders float to the top.
- You pick files individually — nothing is removed in bulk by accident.
- If a file can't be deleted, it stays in the list and tells you; only the ones that succeeded are removed.

<a id="space-lens"></a>

### 🔲 Space Lens

**A visual map of what's using your disk.** Instead of a list, Space Lens draws your storage as a grid of tiles — bigger tile, bigger folder.

- Click any tile to zoom into that folder; use the breadcrumb trail to zoom back out.
- A progress bar shows the scan working in real time.
- This tool is **look-only** — it never deletes anything. It's purely for understanding where your space went.

<a id="malware-removal"></a>

### 🛡️ Malware Removal

**Scans your Mac for known malware** using the open-source ClamAV engine.

- Checks whether ClamAV is installed; if not, it guides you to set it up.
- Scans your home folder, automatically refreshing the malware signature database if it's more than a day old.
- Lists any threats by name and location, and removes them only after you confirm.
- Shows the date of your last scan and the last database update.

> **Note:** ClamAV is a free, separate tool that VaderCleaner uses but does not bundle. See the [developer section](#optional-enabling-the-malware-scanner-clamav) for how to install it. Without ClamAV, every other feature still works normally.

<a id="privacy"></a>

### 🔒 Privacy

**Wipes the trail your web browsers leave behind.** Cache, cookies, browsing history, saved form data, and more.

- Automatically detects installed browsers (Chrome, Safari, Firefox, Brave, Edge).
- For each browser you can choose exactly which kinds of data to clear — nothing is selected for you.
- Optionally clears your macOS "recent items" list too.
- Shows the size of each category before you clear it so you know what you're removing.

<a id="extensions"></a>

### 🧩 Extensions

**Manage the add-ons hooked into your system.** Over time you collect Safari, Mail, Quick Look, Finder, and Siri extensions you no longer use.

- Discovers all of them and groups them by type.
- Select the ones you want gone and confirm to remove them.
- Helps cut down on background clutter and things that can slow your Mac.

<a id="app-uninstaller"></a>

### ❌ App Uninstaller

**Removes apps *completely* — not just the app icon.** Dragging an app to the Trash leaves behind support files, caches, and preferences. This tool finds and removes those too.

- Lists every installed app (with an optional toggle to include built-in system apps).
- Search by name to find what you want fast.
- Pick one app to see its size and all the leftover files associated with it.
- Moves the app and its leftovers to the **Trash** (not a permanent delete), so you can recover it if you change your mind.
- Intentionally one app at a time, to prevent bulk mistakes.

<a id="app-updater"></a>

### 🔄 App Updater

**Tells you which of your apps have updates available.** Keeping apps current is one of the best things you can do for security.

- Checks both the **Mac App Store** and apps that ship their own updates, at the same time.
- Shows only the apps that actually have a newer version, with the version jump (e.g. `12.6 → 12.7`).
- Click through to update via the App Store or the app's own updater.
- Handles being offline gracefully — it tells you it couldn't check rather than pretending everything is current.

<a id="optimization"></a>

### ⚙️ Optimization

**Tunes what runs in the background.** The more apps that launch at startup and run as background services, the slower and busier your Mac.

- See and toggle the apps that open automatically when you log in.
- View and disable background "launch agents" (services that run on a schedule or at boot).
- Free up inactive memory with one click.
- Run macOS's built-in maintenance scripts (the housekeeping tasks the system normally does overnight).

<a id="health-monitor"></a>

### 📊 Health Monitor

**A live dashboard of your Mac's vital signs.** No buttons to press — just a clear, real-time picture.

- CPU usage, memory usage, and free disk space.
- Battery health, drive S.M.A.R.T. status, and FileVault encryption status.
- Color-coded (green / yellow / red) so problems are obvious at a glance.
- Updates every couple of seconds. This screen is read-only and changes nothing on your Mac.

<a id="menu-bar-quick-view"></a>

### 📌 Menu Bar quick view

An optional compact readout in your menu bar showing memory and disk (and optionally CPU and battery) at all times. Click it for a popover with the current stats. Turn it on or off in **Preferences → Menu Bar**.

<a id="notifications"></a>

### 🔔 Notifications

VaderCleaner can alert you when:

- **Malware is found**, and
- **Memory pressure crosses a threshold** you set.

Alerts have a built-in cooldown so you're never spammed. You control all of this in **Preferences → Notifications**.

<a id="preferences"></a>

### 🎛️ Preferences

Four tabs:

- **Notifications** — turn malware/memory alerts on or off and set the memory threshold.
- **Exclusions** — mark folders or files that scans should always skip. Great for protecting a project folder or anything you never want cleaned.
- **Startup** — toggle whether VaderCleaner itself launches when you log in.
- **Menu Bar** — show or hide the menu bar quick view.

---

## Permissions explained (in plain English)

The first time you open VaderCleaner, it asks for **Full Disk Access**. Here's what that means and why:

- macOS protects certain folders so that no app can read them without your explicit say-so.
- Cleaning tools, by their nature, need to *see* those folders to find junk, large files, and privacy data.
- Granting Full Disk Access is a one-time step: VaderCleaner opens the right System Settings page and shows you exactly what to click.
- **You can skip it.** VaderCleaner still runs without Full Disk Access — it just won't be able to scan everything, so results will be incomplete.

Some actions (clearing system-level junk, freeing memory, running maintenance) also need administrator approval. macOS will prompt you for that the same way it does for any installer.

## Your data & safety

VaderCleaner is built to be cautious by design:

- **Everything stays on your Mac.** Scans run locally. The app does not upload your files or send your data anywhere.
- **You're always in control.** Nothing is deleted without you selecting it and confirming.
- **Deleted apps go to the Trash**, not a permanent shredder, so you can undo a mistake.
- **Exclusions are respected** by every scanning tool — set-and-forget protection for folders you care about.
- **Honest results.** If a tool can't check something (e.g. malware scanner not installed, or no Full Disk Access), it says so plainly instead of guessing.

---

## For developers: running it locally

VaderCleaner is a native **Swift + SwiftUI** macOS application.

### Requirements

- **Xcode** with the **macOS 26 SDK**
- **macOS 26.0** deployment target (`MACOSX_DEPLOYMENT_TARGET = 26.0`)
- **Swift 5.9** (`SWIFT_VERSION = 5.9`)
- **No third-party package dependencies.** There is no Swift Package Manager manifest or `Package.resolved` — the project builds with the system SDK only. (App update checking parses other apps' App Store and Sparkle *appcast feeds*; it does **not** embed the Sparkle framework.)

### Get the code

```bash
git clone https://github.com/jayvicsanantonio/VaderCleaner.git
cd VaderCleaner
open VaderCleaner.xcodeproj
```

### Project layout

```text
VaderCleaner/            Main app — SwiftUI views, view models, scanners, services, models
VaderCleanerHelper/      Privileged helper daemon (XPC) for root-level operations
Shared/                  Code shared between app and helper (XPC protocol, deletion policy)
VaderCleanerTests/       Unit tests (XCTest) — view models, scanners, services
VaderCleanerUITests/     End-to-end UI tests (XCUITest)
VaderCleaner.xcodeproj/  Xcode project
```

The app follows a straightforward SwiftUI pattern: one `*View` and one `*ViewModel` per feature, with scanning/cleanup logic isolated in dedicated service types so it can be unit-tested without the UI.

### Targets & schemes

| Target | Purpose |
| --- | --- |
| `VaderCleaner` | The main app |
| `VaderCleanerHelper` | Privileged helper, bundled into the app (not run standalone) |
| `VaderCleanerTests` | Unit tests |
| `VaderCleanerUITests` | UI tests |

Schemes: **`VaderCleaner`** (build/run the app and tests) and **`VaderCleanerHelper`**.

### Build & run

From Xcode: select the **VaderCleaner** scheme and press **Run**. Local builds use Xcode's automatic **"Sign to Run Locally"** ad-hoc signing — no developer certificate is required to run it on your own machine.

From the command line:

```bash
xcodebuild -project VaderCleaner.xcodeproj -scheme VaderCleaner -configuration Debug build
```

For full functionality, grant the app **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access). The in-app onboarding sheet links you straight there.

### The privileged helper

Some operations require root: deleting files under `/Library` and other system locations, freeing inactive memory (`/usr/sbin/purge`), removing system launch agents, and running the macOS `periodic` maintenance scripts.

These are handled by **`VaderCleanerHelper`**, a separate privileged daemon the app talks to over XPC. It registers via `SMAppService`, and macOS will ask for administrator approval the first time. The helper validates every path it's asked to delete (symlink and boundary checks via the shared deletion policy) and verifies the calling app's code-signing identity before accepting a connection. The non-privileged features work without the helper.

### Optional: enabling the malware scanner (ClamAV)

The Malware Removal and Smart Scan malware checks use **ClamAV**, which is not bundled. Install it (for example via Homebrew) to enable that feature:

```bash
brew install clamav
```

VaderCleaner detects `clamscan`/`freshclam` on your `PATH`, refreshes the signature database when stale, and degrades gracefully if ClamAV is absent — every other feature is unaffected.

### Running the tests

The project ships unit tests (`VaderCleanerTests`) and end-to-end UI tests (`VaderCleanerUITests`). Run everything:

```bash
xcodebuild test -project VaderCleaner.xcodeproj -scheme VaderCleaner -destination 'platform=macOS'
```

Run a single unit test class:

```bash
xcodebuild test -project VaderCleaner.xcodeproj -scheme VaderCleaner \
  -destination 'platform=macOS' \
  -only-testing:VaderCleanerTests/SmartScanViewModelTests
```

Run a single UI test:

```bash
xcodebuild test -project VaderCleaner.xcodeproj -scheme VaderCleaner \
  -destination 'platform=macOS' \
  -only-testing:VaderCleanerUITests/FinalPolishUITests/test_launch_sidebarShowsAllElevenSections
```

> **Tip:** macOS UI tests fail to launch if a previous app instance is still attached to the debugger. If a UI test hangs ~60s with "Failed to terminate", quit any running VaderCleaner instance (and its `debugserver`) before re-running.

---

## License

No license file is currently included in this repository. The app's About panel carries the notice **© 2026 Jayvic San Antonio**. Until a `LICENSE` file is added, all rights are reserved by the copyright holder.

---

*VaderCleaner — a native macOS cleaner: junk, large files, malware, privacy, and system health.*
