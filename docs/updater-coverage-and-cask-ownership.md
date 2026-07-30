# Updater: coverage reporting and Homebrew cask ownership

Design spec for two changes to the Applications Manager's Updater pane.

Both address the same defect from different angles: **the pane reports a
number the user reads as "your apps are current", and that reading is
false.** Change 1 makes the unchecked population visible. Change 2 stops
two subsystems from managing the same app in conflicting directions.

## Measured baseline

Taken on the development machine, 2026-07-30. These numbers are what
justify the work; re-measure before assuming they still hold.

`/Applications` contains 50 `.app` bundles:

| Signal | Count | Probe status today |
|---|---|---|
| `_MASReceipt/receipt` (Mac App Store) | 18 | checked |
| `SUFeedURL` (Sparkle) | 1 | checked |
| `KSUpdateURL` (Google Keystone) | 2 | `.skipped`, silently |
| `Contents/Frameworks/Squirrel.framework` | 10 | `.skipped`, silently |
| No update signal at all | 19 | `.skipped`, silently |

So **19 of 50 apps are checked and 31 are not**, and the UI does not say
so. The single "Web" row in the Updater is the only Sparkle app on the
machine.

Concrete consequence: Google Chrome is at `150.0.7871.188` with
`151.0.7922.72` available. It carries `KSUpdateURL` and no `SUFeedURL`,
so `UpdateProbe` skips it and `AppUpdaterViewModel` discards the skip.
Chrome appears nowhere in "All Updates" — it surfaces only as a row
buried in the separate Homebrew list.

Homebrew state on the same machine:

- 18 installed casks per `brew list --cask`, but `brew info --json=v2
  --installed` returned only 16 — `docker` and `windsurf` were omitted.
- `brew outdated --json=v2` reports 7 outdated casks; the same command
  with `--greedy` reports 13. The 6 extra are casks marked
  `auto_updates: true`, which Homebrew hides by default.
- 14 of the 16 resolvable casks are `auto_updates: true`.
- `cursor` is installed per Homebrew, but no `Cursor.app` exists on disk;
  its Caskroom holds only `3.7.21,<sha>.upgrading` — an interrupted
  upgrade.

---

# Change 1 — Report coverage, not just findings

## Problem

`UpdateProbeOutcome.skipped` already exists and already means "no request
was ever made". `AppUpdaterViewModel.checkForUpdates()` matches it and
does nothing:

```swift
case .skipped:
    // No request was made — neither evidence the
    // network is up nor that it is down.
    break
```

That is correct for the offline decision and wrong as a stopping point.
The information needed to tell the user "31 of your 50 apps were never
checked" is computed and then dropped.

Two further problems block simply counting it:

1. `.skipped` is one bucket. An app that updates itself through Keystone
   is fine; an app with no updater at all is a genuine blind spot.
   Collapsing them produces a scary number that is mostly noise.
2. `UpdateProbe.outcomes(for:)` returns `[UpdateProbeOutcome]` in
   *completion order*, discarding which app produced which outcome. A
   coverage list needs the app back.

## Design

### New value types

`UpdateChannel.swift` — classification of how an installed app receives
updates, derived from the bundle plus (for casks) the Homebrew ownership
map from Change 2.

```swift
/// Why an app was not queried for updates.
enum SelfUpdater: String, Hashable, Sendable {
    case keystone   // KSUpdateURL — Google's Omaha channel
    case squirrel   // Contents/Frameworks/Squirrel.framework
    case homebrewCask   // cask marked auto_updates
}

/// How an installed app receives updates.
enum UpdateChannel: Hashable, Sendable {
    case appStore
    case sparkle(feedURL: URL)
    case homebrewCask(token: String)
    /// Ships its own updater we cannot query, but is not neglected.
    case selfUpdating(SelfUpdater)
    /// No detectable update mechanism. The real blind spot.
    case unmonitored
}
```

Precedence when several signals are present (VS Code is both a cask and
a Squirrel app): **cask > appStore > sparkle > selfUpdating >
unmonitored.** Cask wins because it determines the *action* — see
Change 2. Whether a cask self-updates is carried alongside as a flag,
not as a competing case.

### Classifier

`AppUpdateChannelClassifier.swift` — a `Sendable` struct following the
repo's injected-collaborator convention, with a `live()` factory.

```swift
struct AppUpdateChannelClassifier: Sendable {
    typealias ResolveCask = @Sendable (AppInfo) -> CaskOwnership?
    func channel(for app: AppInfo) -> UpdateChannel
}
```

Detection, in precedence order:

- **Cask** — `resolveCask(app) != nil` (Change 2's map).
- **App Store** — `app.isAppStore`, already on `AppInfo`.
- **Sparkle** — existing `DefaultSparkleUpdateChecker.feedURL(for:)`.
- **Keystone** — `KSUpdateURL` present and non-empty in `Info.plist`.
  Read via `Bundle(url:).object(forInfoDictionaryKey:)`, matching how
  `feedURL(for:)` already reads `SUFeedURL`.
- **Squirrel** — `Contents/Frameworks/Squirrel.framework` exists.
- Otherwise `.unmonitored`.

### Probe changes

`UpdateProbe.outcomes(for:)` must return the app alongside the outcome:

```swift
struct UpdateProbeResult: Sendable {
    let app: AppInfo
    let outcome: UpdateProbeOutcome
}
```

and `.skipped` gains the reason:

```swift
case skipped(UpdateChannel)   // .selfUpdating(_) or .unmonitored
```

`UpdateProbe.updates(in:)` and `availableUpdates(for:)` keep their
current signatures and behaviour by mapping over `\.outcome`, so the
Applications dashboard and Smart Scan call sites are unchanged.

### Coverage summary

```swift
struct UpdateCoverage: Equatable, Sendable {
    let checked: Int          // feed reached: .update or .noUpdate
    let unreachable: Int
    let selfUpdating: [AppInfo]
    let unmonitored: [AppInfo]
    var total: Int { checked + unreachable + selfUpdating.count + unmonitored.count }
}
```

`AppUpdaterViewModel` gains `private(set) var coverage: UpdateCoverage`,
populated in the same loop that already walks outcomes. The offline
decision (`updates.isEmpty && !anyReachable && anyUnreachable`) is
unchanged — `.skipped` stays neutral in it, for exactly the reason the
existing comment gives.

### UI

In `ApplicationsUpdaterPane.swift`:

- A subtitle under the "All Updates" header:
  *"Checked 19 of 50 apps."*
- A new facet group **Coverage** below Stores, with two rows:
  - **Self-updating** (count) — apps that keep themselves current.
    Detail copy names the mechanism per row ("Updates through Google
    Software Update"). Reassurance, not a to-do list.
  - **Not monitored** (count) — apps with no detectable update path.
    This is the actionable one and it is where Chrome-class surprises
    would show up if Keystone detection did not exist.

Both facets list `AppInfo` rows, not `UpdateInfo` — there is no version
pair to show. `UpdaterFacet` gains `.selfUpdating` and `.unmonitored`,
and `recompute()` returns empty for them (same pattern as the existing
`.homebrew` case, which is already a separate list).

## Tests

`UpdateProbeTests` (extend):
- `.skipped` carries `.unmonitored` for an app with no signals.
- `.skipped` carries `.selfUpdating(.keystone)` for a `KSUpdateURL` bundle.
- `.skipped` carries `.selfUpdating(.squirrel)` for a Squirrel bundle.
- Each result pairs with the app that produced it, under concurrency
  (completion order must not scramble the association).

`AppUpdateChannelClassifierTests` (new), against temp-dir bundle fixtures:
- Each signal in isolation yields its channel.
- Precedence: cask beats App Store beats Sparkle beats Keystone.
- Empty-string `KSUpdateURL` is not treated as Keystone (mirrors the
  existing `SUFeedURL` empty check).
- A missing/unreadable `Info.plist` yields `.unmonitored`, never a crash.

`AppUpdaterViewModelTests` (extend):
- Coverage counts partition the input exactly: `total == apps.count`.
- A run of all-skipped apps yields `.ready` with zero updates and a
  non-zero `unmonitored` count — **not** `.failed`. This is the
  regression that would reintroduce today's silence.
- Coverage is recomputed, not accumulated, across two `checkForUpdates()`
  passes.
- A superseded generation does not overwrite fresh coverage.

---

# Change 2 — Resolve Homebrew cask ownership

## Problem

A cask installs a real `.app` into `/Applications`. `AppDiscovery` finds
it, so one app can be represented twice in the same pane: once as an
`UpdateInfo` row (if it has a Sparkle feed or MAS receipt) and once as a
`BrewOutdatedItem` under the Homebrew facet. The two rows disagree about
what "update" means.

Acting on the app-side row for a cask-owned app **downloads a disk image
and overwrites a Caskroom-managed install**, desyncing Homebrew's
manifest from disk. The user then has an app Homebrew believes is at the
old version and will happily "upgrade" back over.

Today this is latent rather than firing, because the machine happens to
have no app that is both a cask and Sparkle-fed. It is one `brew install`
away from firing.

There is a second, live symptom: Homebrew's version metadata and the
app's own `Info.plist` drift apart for `auto_updates` casks, because the
app updates itself without telling Homebrew. Neither surface knows the
other exists, so neither can correct the other.

## Design

### Ownership map

`BrewCaskOwnership.swift`:

```swift
struct CaskOwnership: Hashable, Sendable {
    let token: String
    let autoUpdates: Bool
    /// App bundle names the cask installs, e.g. "Visual Studio Code.app".
    let appNames: [String]
    /// Absolute targets when the cask declares an explicit `target:`.
    let appTargets: [URL]
}
```

Source: `brew info --json=v2 --installed`, already reachable through the
existing `BrewRunning.runCapturing` seam. No new process plumbing.

### Parsing

`BrewOutputParser.parseInstalledCasks(_ data: Data) throws -> [CaskOwnership]`,
alongside the existing `parseOutdatedJSON`. Kept pure, per the file's
stated contract.

The `artifacts` array is heterogeneous and needs a tolerant decoder:

```json
"artifacts": [
  { "app": ["Visual Studio Code.app"] },
  { "app": ["Foo.app", { "target": "/Applications/Bar.app" }] },
  { "binary": ["..."] },
  { "zap": [ ... ] }
]
```

Rules:
- Only `app` entries are read; every other artifact key is ignored.
- Within an `app` array, string elements are bundle names and dictionary
  elements may carry `target` (an absolute destination path).
- Unknown shapes are skipped, never thrown on. A cask with an
  unparseable artifact yields a `CaskOwnership` with empty `appNames`,
  which the matcher treats as unresolved (see fail-safe below).

### Matching an app to a cask

`resolveCask(for: AppInfo) -> CaskOwnership?`:
1. If any `appTargets` path equals `app.bundleURL` (standardized), match.
2. Else if any `appNames` equals `app.bundleURL.lastPathComponent`, match.
3. Else no match.

### Fail-safe: the JSON is incomplete

**Measured: `brew info --json=v2 --installed` returned 16 casks while
`brew list --cask` returned 18.** `docker` and `windsurf` were omitted —
most likely renamed or deprecated casks that no longer resolve. So
*absence from the ownership map is not evidence that an app is
unmanaged.*

The map therefore carries a second, cheaper signal: the set of token
directory names under `$(brew --prefix)/Caskroom/`. Then:

```
resolvable   = tokens in the info JSON
installed    = tokens in Caskroom
unresolved   = installed - resolvable
```

When `unresolved` is non-empty, the ownership map is marked
**incomplete**. While incomplete, an app that matches no cask is treated
as *ownership unknown* rather than *not brew-managed*, and the Updater
must not offer it a direct-download update. It falls back to opening the
vendor page, which is safe under either truth.

This rule is the whole point of the change: the failure mode being
prevented is silently clobbering a managed install, so ambiguity must
resolve toward inaction.

### Broken cask installs

A token whose Caskroom directory contains only a `*.upgrading` version
and whose app is absent from disk (measured: `cursor`) is not an update —
it is an interrupted install. Surface it in the Homebrew facet as a
distinct state with `brew reinstall --cask <token>` as the remedy. Do not
count it toward the outdated total.

### Version truth for cask-owned apps

For an app matched to a cask, `AppInfo.version` (read from `Info.plist`)
is authoritative for *what is installed*; Homebrew's
`installed_versions` reflects only what Homebrew last put there. When
they disagree, prefer the `Info.plist` value for display and note that
the app has updated itself since Homebrew last touched it.

### Greedy or not

`brew outdated` hides `auto_updates` casks unless `--greedy` is passed
(measured: 7 vs 13). **Keep the default non-greedy.** Greedy re-reports
apps that have already updated themselves, and upgrading them through
Homebrew re-downloads a version the user already runs. The 6 hidden
casks are instead represented on the app side as
`.selfUpdating(.homebrewCask)` under Change 1's Coverage group, which is
the honest place for "fine, not your problem".

### Routing the action

In `ApplicationsManagerView.updateSelected()`, an `UpdateInfo` whose
channel is `.homebrewCask(token:)` must not reach
`NSWorkspace.open`. Route it to
`HomebrewViewModel.upgrade(.some([token]))`, which already streams,
handles pinning, cancels cleanly, and refreshes the outdated list.

Row presentation for a cask-owned app: source label reads **"Homebrew"**
rather than "Web" or "App Store", so the user can see which subsystem
owns it before acting.

## Tests

`BrewOutputParserCaskOwnershipTests` (new), fixture-driven:
- Simple `{"app": ["Foo.app"]}` yields one app name.
- Mixed array with a `{"target": "/Applications/Bar.app"}` yields both
  the name and the absolute target.
- Non-`app` artifacts (`binary`, `zap`, `pkg`) are ignored.
- `auto_updates` absent decodes as `false` (matches the existing
  `pinned` default in `parseOutdatedJSON`).
- Malformed artifact entries are skipped without throwing; a cask with
  only malformed artifacts yields empty `appNames`.
- Empty `casks` array yields an empty map, not an error.

`BrewCaskOwnershipTests` (new):
- Name match and target match each resolve.
- A `~/Applications` copy of a cask app does **not** match a cask whose
  target is `/Applications` — two installs, one managed.
- Caskroom tokens absent from the JSON mark the map incomplete.
- An incomplete map reports ownership as unknown for unmatched apps.
- A `*.upgrading`-only Caskroom token with no app on disk is reported as
  a broken install, not an update.

`AppUpdaterViewModelTests` / `ApplicationsManagerView` wiring (extend):
- A cask-owned app with a Sparkle feed is routed to `brew upgrade`, and
  the opener is **never** called. This is the regression test for the
  clobber.
- With an incomplete ownership map, an unmatched app is not offered a
  direct download.
- Cask-owned rows report source "Homebrew".

## Sequencing

Change 1 is independent and lands first: it is additive, touches no
action path, and its `UpdateChannel` type is what Change 2 plugs into.
Change 2 depends on `UpdateChannel.homebrewCask` existing.

Both must keep the Swift 6 language mode clean across app, `Shared/`,
helper, and **both test targets** — verify with a full
`clean build-for-testing`, not an incremental build.
