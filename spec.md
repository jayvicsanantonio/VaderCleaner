# VaderCleaner — macOS App Specification

## Overview

VaderCleaner is a personal-use native macOS cleaning and optimization app that closely mirrors the UX/UI and feature set of CleanMyMac. It is not intended for App Store distribution, which means it is not subject to macOS sandbox restrictions and can have deep system access.

---

## Technology Stack

- **Language:** Swift
- **UI Framework:** SwiftUI
- **Platform:** macOS (native)
- **Malware Engine:** ClamAV (open source, free)
- **Distribution:** Personal use only (direct install, no App Store)

---

## App Behavior

- **Startup:** Launches automatically on login via a Login Item
- **Menu Bar:** Always-on menu bar icon showing live RAM usage and disk space stats
- **Scanning:** All scans are manually triggered by the user — no scheduled or automatic scans
- **Preview Before Clean:** Every scan shows a detailed preview of what will be deleted (with file sizes broken down by category) before any action is taken. The user must explicitly click "Clean" to confirm deletion. Individual categories can be unchecked to exclude them.

---

## UI/UX Design

- Closely mirrors CleanMyMac's sidebar-based layout
- Left sidebar navigation for all major feature sections
- Main content area shows scan results, previews, and controls
- Space Lens uses a **treemap** visualization (not sunburst/radial) for better at-a-glance readability of disk usage

---

## Features

### 1. Smart Scan
A one-click combined scan that runs System Junk cleanup, Malware Removal, and Performance Optimization together and presents a unified summary of findings.

---

### 2. System Junk
Scans for and removes:
- System cache files
- User cache files
- System logs and user logs
- Language files for unused languages
- Mail attachments stored locally
- Old iOS/iPadOS device backups
- Trash bins across all connected drives

**Behavior:** Scan first, show detailed preview broken down by category, user confirms before deletion. Individual categories can be unchecked.

---

### 3. Large & Old Files
Finds files on disk that are large and/or haven't been accessed in a long time. Presents them in a sortable list so the user can decide what to delete.

---

### 4. Space Lens
A visual interactive disk space analyzer using a **treemap** layout. Folders are displayed as nested rectangles sized proportionally by disk usage, making it easy to spot the biggest space consumers at a glance. Users can drill into folders by clicking.

---

### 5. Malware Removal
- Uses **ClamAV** as the underlying scan engine
- Maintains an up-to-date ClamAV signature database
- Scans for malware, adware, and ransomware
- Reports findings with file paths and threat names
- Allows the user to remove detected threats

---

### 6. Privacy
- Auto-detects all installed browsers on the machine
- Supports Safari, Chrome, Firefox, Brave, Arc, Opera, Edge, and any other installed browser
- Clears: browsing history, download history, cookies, cached data, saved form data
- Also clears: recently opened files list, app-specific chat histories

---

### 7. Extensions Manager
Manages and allows removal of:
- Safari extensions
- Browser extensions (Chrome, Firefox, etc.)
- Mail plugins
- Internet plugins
- Login items that were installed by apps

---

### 8. App Uninstaller
- Lists all installed applications
- Removes selected apps along with all associated files (preferences, caches, application support files, logs, launch agents, etc.)
- Supports both App Store and non-App Store apps

---

### 9. App Updater
- Checks for updates for all installed apps
- Supports **App Store apps** (via Mac App Store)
- Supports **non-App Store apps** using the **Sparkle** framework (the most common update mechanism used by indie Mac developers)
- Presents a list of available updates and allows the user to trigger updates

---

### 10. Optimization
- **Login Items Manager:** View and remove apps that launch at startup
- **Launch Agents Manager:** View and remove background agents installed by apps
- **RAM Flushing:** Frees up inactive memory on demand
- **Maintenance Scripts:** Runs macOS periodic maintenance scripts (daily, weekly, monthly)

---

### 11. Menu Bar App
- Always visible in the macOS menu bar
- Displays live stats: RAM usage and available disk space
- Clicking the menu bar icon opens a quick-access dropdown with key stats and a button to open the full VaderCleaner window

---

### 12. Health Monitor
Mirrors CleanMyMac's health monitoring. Displays:
- **Battery Health:** cycle count, maximum capacity, condition
- **Disk Health:** SMART status (Good / Failing)
- **RAM Pressure:** current memory usage and pressure level
- **CPU Load:** current CPU usage
- **Disk Space:** used vs. available storage

---

### 13. Notifications
Sends macOS system notifications for the following events (each individually toggleable in Preferences):
- **Low Disk Space:** when available disk space drops below a configurable threshold (default: 10% free)
- **High RAM Pressure:** when memory pressure reaches a critical level
- **Malware Detected:** immediate alert if a threat is found during a scan
- **Large Files Found:** reminder when large old files are detected

---

### 14. Preferences / Settings Window
Mirrors CleanMyMac's preferences panel. Includes:
- **Notifications:** toggle each notification type on/off; configure disk space threshold
- **Exclusions:** a list of files and folders that VaderCleaner will never scan or clean
- **Startup:** toggle whether VaderCleaner launches automatically on login
- **Menu Bar:** toggle the always-on menu bar icon on/off

---

## Features Explicitly Excluded

- **Shredder (Secure File Deletion):** Dropped. On modern Macs with SSDs and FileVault enabled, secure overwrite passes are largely ineffective due to SSD wear-leveling. FileVault provides stronger protection. The feature adds complexity with minimal real-world benefit.
- **Scheduled Automatic Scans:** All scans are manually triggered only.

---

## Technical Notes

- Since this is a personal-use app not distributed via the App Store, it does not need to comply with macOS App Sandbox restrictions. This allows deeper system access required for features like launch agent management, SMART disk status, and system junk cleaning.
- ClamAV should be bundled with the app or installed via Homebrew, with the app handling signature database updates via `freshclam`.
- Browser detection should be dynamic — scan known install locations for all major browsers and handle whichever are present.
- Sparkle framework integration for the App Updater requires checking each non-App Store app's `SUFeedURL` in its `Info.plist` to find its update feed.
- FileVault status should be checked and surfaced in the Health Monitor as an informational item.
