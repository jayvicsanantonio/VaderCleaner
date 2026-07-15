# Requirements Document

## Introduction

The Homebrew Manager is a new manager surface in VaderCleaner that lets a user efficiently and cleanly update and uninstall software installed through Homebrew — both formulae (CLI tools and libraries) and casks (GUI apps and binaries). It parallels the existing App Updater and App Uninstaller: a glanceable dashboard of what is outdated, a one-action upgrade path, and a dependency-aware uninstall that removes orphaned dependencies and reclaims cached-download disk space in the same sweep.

The value over dropping the user into Terminal is safety and legibility. Homebrew already tracks exactly what it installed and the full dependency graph between packages, so VaderCleaner can show *what depends on a package before it is removed*, surface *orphaned dependencies that are now safe to sweep*, and report *reclaimable disk from stale versions and cached downloads* up front. All of this runs as ordinary streamed `brew` invocations with cancellation, matching how the ClamAV scan already drives long-running child processes.

The feature is constrained by three facts already true in the codebase: the app is not sandboxed (it may spawn `brew` directly), Homebrew refuses to run as root (so this must run as the invoking user and must **not** go through the privileged XPC helper), and `ProcessLineStreamer` already provides the streaming/cancellable process engine this feature needs. Homebrew may be absent entirely, so a first-class "not installed" state is a requirement, not an afterthought.

## Requirements

### Requirement 1: Homebrew Availability Detection

**User Story:** As a user who may or may not have Homebrew installed, I want the app to detect whether Homebrew is present, so that the feature only offers actions it can actually perform.

#### Acceptance Criteria
1. WHEN the Homebrew Manager is opened THEN the system SHALL locate the `brew` executable by checking `/opt/homebrew/bin/brew` (Apple silicon) then `/usr/local/bin/brew` (Intel), in that order, and use the first that exists.
2. IF no `brew` executable is found at any known prefix THEN the system SHALL present a "Homebrew not installed" empty state and SHALL NOT attempt any `brew` invocation.
3. WHEN the "Homebrew not installed" empty state is shown THEN the system SHALL offer a link or copyable command to install Homebrew, and SHALL NOT present upgrade, uninstall, or cleanup controls.
4. WHERE the detected `brew` path is later found to be non-executable or fails to run, the system SHALL surface a failure state with the underlying error rather than silently showing an empty inventory.

### Requirement 2: Non-Root, User-Context Execution

**User Story:** As a user, I want Homebrew operations to run safely as my own account, so that they succeed and do not corrupt my Homebrew installation.

#### Acceptance Criteria
1. WHEN any `brew` command is invoked THEN the system SHALL run it as a normal child `Process` in the user's context and SHALL NOT route it through the privileged XPC helper.
2. WHEN a child `brew` process is spawned THEN the system SHALL derive its environment from `ProcessInfo.processInfo.environment` so that `HOME`, `PATH`, and locale are preserved, rather than replacing the environment wholesale.
3. IF a `brew` invocation would require root THEN the system SHALL NOT attempt to elevate it via the helper, and SHALL treat it under the sudo-handling rules of Requirement 8.

### Requirement 3: Installed-Package Inventory

**User Story:** As a user, I want to see everything I installed through Homebrew, so that I can decide what to update or remove.

#### Acceptance Criteria
1. WHEN the inventory loads THEN the system SHALL list installed formulae (via `brew list --formula --versions`) and installed casks (via `brew list --cask --versions`) with their names and installed version(s).
2. WHEN the inventory loads THEN the system SHALL mark which formulae are top-level requests (via `brew leaves --installed-on-request`) versus dependencies pulled in by other packages.
3. WHILE the inventory is displayed THE system SHALL allow the user to distinguish formulae from casks.
4. IF the inventory query returns no installed packages THEN the system SHALL present an "empty inventory" state distinct from the "Homebrew not installed" state of Requirement 1.
5. WHEN the inventory walk runs THEN it SHALL execute off the main actor so the UI is not blocked while `brew` enumerates packages.

### Requirement 4: Outdated Dashboard

**User Story:** As a user, I want a glanceable summary of what Homebrew packages have updates available, so that I know at a glance whether action is needed.

#### Acceptance Criteria
1. WHEN the user requests an update check THEN the system SHALL run `brew update` to refresh formula/cask definitions, then `brew outdated --json=v2` to enumerate outdated formulae and casks.
2. WHEN parsing outdated results THEN the system SHALL read each package's installed (current) version and candidate (available) version from the JSON payload, distinguishing formulae from casks.
3. WHEN an outdated package is reported as pinned THEN the system SHALL mark it as pinned and SHALL exclude it from any "upgrade all" action.
4. WHEN the outdated check completes THEN the system SHALL present a count of available updates for the section glance, consistent with how the App Updater surfaces available-update counts.
5. IF `brew update` fails (e.g. no network) THEN the system SHALL surface the failure and SHALL still attempt to report outdated packages from local metadata where possible.

### Requirement 5: Upgrade (All or Selected)

**User Story:** As a user, I want to upgrade all or selected outdated Homebrew packages in one action, so that I can keep them current without typing commands.

#### Acceptance Criteria
1. WHEN the user chooses "upgrade all" THEN the system SHALL run `brew upgrade` and SHALL exclude pinned formulae from the operation.
2. WHEN the user selects specific packages to upgrade THEN the system SHALL run `brew upgrade <name>` (or the cask equivalent) for exactly the selected packages.
3. WHILE an upgrade is running THE system SHALL stream `brew` output line by line to a live progress view.
4. WHEN an upgrade operation completes THEN the system SHALL refresh the outdated dashboard so the upgraded packages no longer appear.
5. IF an individual package upgrade fails THEN the system SHALL report which package failed with the underlying `brew` message and SHALL continue with the remaining selected packages where Homebrew allows.

### Requirement 6: Dependency-Aware Uninstall

**User Story:** As a user, I want to remove a Homebrew package while being warned about what depends on it, so that I do not break other installed tools.

#### Acceptance Criteria
1. WHEN the user selects a package to uninstall THEN the system SHALL query its installed reverse-dependencies via `brew uses --installed <name>` before removal.
2. IF one or more installed packages depend on the selected package THEN the system SHALL warn the user, list the dependents, and require explicit confirmation before proceeding.
3. WHEN the user confirms removal THEN the system SHALL run `brew uninstall <name>` (or the cask equivalent) for the confirmed packages.
4. WHEN presenting removable packages THEN the system SHALL indicate which are leaves (safe to remove with no dependents) versus depended-upon, using the `brew leaves` and `brew uses` results.
5. WHILE an uninstall is running THE system SHALL stream `brew` output line by line and SHALL allow the operation to be cancelled.
6. WHEN an uninstall completes THEN the system SHALL refresh the inventory so removed packages no longer appear.

### Requirement 7: Cleanup and Reclaim

**User Story:** As a user, I want to reclaim disk from orphaned dependencies and stale Homebrew downloads, so that removing software actually frees space.

#### Acceptance Criteria
1. WHEN the user requests a cleanup preview THEN the system SHALL run `brew cleanup -n` (dry run) and SHALL surface the reclaimable byte total parsed from its output.
2. WHEN the user confirms cleanup THEN the system SHALL run `brew cleanup` to remove stale versions and cached downloads.
3. WHEN the user requests orphan removal THEN the system SHALL run `brew autoremove` to remove dependencies no longer required by any installed package, and SHALL show which packages it removed.
4. WHERE `brew autoremove` and `brew cleanup` are offered together after an uninstall, the system SHALL let the user apply the clean sweep as part of the same flow rather than requiring a separate visit.
5. IF the reclaimable total cannot be parsed from `brew cleanup -n` output THEN the system SHALL still allow cleanup to run but SHALL present the reclaim amount as unavailable rather than a fabricated number.

### Requirement 8: Interactive/Sudo Command Handling

**User Story:** As a user removing a cask whose uninstaller needs administrator rights, I want the app to handle it gracefully, so that the operation does not silently hang forever.

#### Acceptance Criteria
1. WHEN a cask uninstall or upgrade invokes a `sudo`/password prompt on stdin THEN the system SHALL NOT block indefinitely waiting on that prompt.
2. WHEN an operation is detected to require interactive elevation THEN the system SHALL surface a clear message that the package must be handled in Terminal, and SHALL provide the exact `brew` command to run.
3. WHERE a `brew` operation stalls beyond a bounded time with no output progress THEN the system SHALL allow the user to cancel it and SHALL report it as requiring manual handling rather than reporting success.

### Requirement 9: Streaming Progress and Cancellation

**User Story:** As a user running long Homebrew operations, I want live progress and the ability to cancel, so that I am never stuck watching a frozen screen.

#### Acceptance Criteria
1. WHEN any long-running `brew` operation (update, upgrade, uninstall, cleanup, autoremove) runs THEN the system SHALL stream its stdout line by line using the existing `ProcessLineStreamer` engine.
2. WHEN the user cancels a running operation THEN the system SHALL terminate the child `brew` process (SIGTERM) and return to a stable, non-partial UI state.
3. WHILE an operation is running THE system SHALL disable conflicting actions so two mutating `brew` operations cannot run concurrently.
4. WHEN an operation finishes THEN the system SHALL report its terminating status (success or the non-zero exit and captured error) to the user.

### Requirement 10: Testability via Injected Command Seam

**User Story:** As a developer, I want Homebrew execution behind an injectable protocol, so that the view model can be unit-tested with fixture JSON and no real `brew` on the machine.

#### Acceptance Criteria
1. WHEN the Homebrew view model is constructed THEN all `brew` interactions SHALL be reached through an injected `BrewRunning`-style protocol seam, mirroring the existing `AppDiscovering` seam.
2. WHEN unit tests run THEN they SHALL drive every state transition (available, empty, outdated, upgrading, uninstalling, cleanup, failure, sudo-required) using in-memory stub responses and JSON fixtures, without invoking real `brew`.
3. WHERE `brew` JSON output is parsed THEN parsing SHALL be a pure function over fixture data so malformed/edge-case payloads can be covered by tests.
4. WHEN the availability detector is tested THEN the candidate prefix paths SHALL be injectable so tests do not depend on the host machine's Homebrew install.

### Requirement 11: Navigation and Section Placement

**User Story:** As a user, I want to reach the Homebrew Manager from a predictable place in the app, so that it feels like a native part of VaderCleaner.

#### Acceptance Criteria
1. WHEN the Homebrew Manager is added THEN it SHALL be reachable as a manager surface consistent with the existing App Updater/App Uninstaller navigation (either a destination under the Applications section or its own navigation section — resolved in design).
2. WHERE the surface exposes a scan/refresh entry point THEN it SHALL carry a stable accessibility identifier consistent with the app's `sidebar.*` / `section.*.scan` conventions.
3. WHEN the section is shown and Homebrew is installed THEN it SHALL present a glance summary (counts of installed packages, available updates, and reclaimable space) before the user drills into any list.
