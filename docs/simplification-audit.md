<!-- Snapshot. Every line number, count and status below was true at the
     commit named in the baseline; verify before acting on any of it. The
     same caveat docs/dead-code-report.md carries, for the same reason. -->

# VaderCleaner — Simplification Audit (read-only)

**Baseline:** branch `fix/smart-scan-bulk-select-and-verdict` @ `348d02c`, plus 8 uncommitted
files from prior session work (DuplicateScanner, MyClutterViewModel, ProtectionDashboardView,
ProtectionDashboardViewModel, SimilarImageScanner + 3 test files). Audit reads the working
tree as-is. **No repository file is modified by this audit**; this report lives outside the repo.

**Coverage contract:** 285/285 `VaderCleaner/*.swift` mechanically partitioned by
`partition.py` (first-match-wins regex). 0 unassigned. 1 multi-match resolved below.
Non-app subsystems added by hand (S24–S27).

## Subsystem inventory

| ID | Name | Files | Status |
|----|------|-------|--------|
| S01 | SmartScan care model + engine | 13 | queued |
| S02 | SmartScan view model + settings | 3 | queued |
| S03 | SmartScan UI surfaces | 6 | queued |
| S04 | Review screens + manager shell | 20 | queued |
| S05 | Cleanup / System Junk | 18 | queued |
| S06 | My Clutter | 18 | queued |
| S07 | Space Lens | 15 | queued |
| S08 | Applications section | 29 | queued |
| S09 | Updates + Homebrew | 27 | queued |
| S10 | Protection: malware | 13 | queued |
| S11 | Protection: privacy | 15 | queued |
| S12 | Protection dashboard UI | 4 | queued |
| S13 | Performance section | 16 | queued |
| S14 | Telemetry + health | 11 | queued |
| S15 | Helper + XPC (incl. `Shared/`, `VaderCleanerHelper/`) | 5+4 | queued |
| S16 | File scanning core | 9 | queued |
| S17 | App shell + navigation | 17 | queued |
| S18 | Menu bar + scan disc | 7 | queued |
| S19 | Settings + preferences (owns `SettingsRouter`) | 11 | queued |
| S20 | Notifications | 5 | queued |
| S21 | Onboarding + welcome | 10 | queued |
| S22 | Design system + shared utils | 12 | queued |
| S23 | Subprocess plumbing | 1 | queued |
| S24 | Test infrastructure (`VaderCleanerTests/Helpers`) | — | queued |
| S25 | UI tests | 11 | queued |
| S26 | Build + tooling (`project.yml`, `Scripts/`, CI, lint cfg) | — | queued |
| S27 | Generated-contract ownership (XcodeGen ↔ pbxproj ↔ scheme) | — | queued |

**Multi-match resolution:** `SettingsRouter` matched S17 and S19. Assigned to **S19**
(settings-domain routing); S17 boundary explicitly excludes it.

## Findings (coordinator-validated only)

### F1 — S01 — `CareFinding.kind` duplicates the discriminant `payload` already carries
ACCEPTED. Verified independently: `CareFinding.swift:50-108` (Kind, 17 cases) vs `:112-130`
(Payload, 17 cases); `init(kind:payload:)` at `:149-154` checks nothing. Coordinator grep over
all construction sites: 17 distinct pairs, **all identity**, 116 sites, zero intentional
mismatch. 272 representable-but-wrong combinations, all failing *silently* (title from `kind`,
metric from `payload` — `CareFindingCopy.swift:28` vs `:303`). Fix: `Payload.kind` derived
property + `init(payload:)`. Confidence HIGH.

### F2 — S01 — shared app discovery encoded positionally in the lane table
ACCEPTED (narrowed). Verified: `CareScanEngine.swift:77` lane literal vs `:176` duplicate
membership set; `:179` `unitStarted(lane[0])`; `:196` `index == 0` skip. Moving an app unit to
another lane yields `runners.unusedApps([])` → empty → `.completed` → dropped as empty: a
silent wrong answer with no failure path. Confidence MEDIUM-HIGH.

### F3 — S06 — one four-category walk written three times
ACCEPTED. Verified byte-identical loops: `MyClutterSelectionSeed.swift:42-57` vs
`MyClutterViewModel.swift:385-406` (`rebuildSizeMap`), same order, coupling maintained *by
comment* (`MyClutterSelectionSeed.swift:39-41`). Third walk: `recomputeDerived()`. Concrete
cost: the scan path builds this off-main (documented as "costs seconds"), the prune path runs
the whole O(all-files) rebuild on the main actor. Confidence HIGH.

### F4 — S06 — `selectedURLs` unconstrained relative to the reviewable index
ACCEPTED (diagnosis) / NARROWED (remedy). Verified: `MyClutterManagerView.swift:585-596` wires
`onToggleSelect` for *every* strip item incl. the kept original;
`MyClutterThumbnailStripItem.swift:70` draws the checkbox unconditionally; originals are never
in `sizeByURL`/`categoriesByURL`. Result: box renders checked, totals gain 0, footer still says
"No Items Selected", Remove skips it, and the stray URL survives `prune`. Remedy (gate at the
index vs. remove the checkbox) is a product call. Confidence MEDIUM-HIGH.

### F5 — S08 — extensions batch removal has no batch state
ACCEPTED. Verified: `ApplicationsManagerView.swift:479-485` loops `await …remove(item)` over a
**single-item** phase machine (`ExtensionsManagerViewModel.swift:99-113`), so item N's
`.failed` is overwritten by item N+1's `.removing`. `.failed(stage:.removing)` has no
production consumer. Correct shape already exists in-boundary
(`AppUninstallerViewModel.uninstallSelected()`). Confidence HIGH.

### F6 — S08 — "Select: All" ignores the active search filter
ACCEPTED. Verified: `ApplicationsViewModel.swift:343-346, :399-402, :458-461` all read the full
`phase` payload, not the visible rows. Destructive path: filter to one installer → Select All →
Remove trashes *every* installer in the scan. Contradicts the documented opt-in rationale at
`:208-211`. The correctly-scoped contract `selectAllForUninstall(_ ids:)`
(`AppUninstallerViewModel.swift:415`) has **zero production callers** (tests only). Confidence HIGH.

### F7 — S02 — four lifecycle flags live beside the `Phase` enum
ACCEPTED (coordinator-authored; S02 audited inline). `SmartScanViewModel.swift:105` `phase`
plus `:138` `isReviewing`, `:144` `isConfirmingRun`, `:148` `runProgress`, `:154`
`isRefreshingFindings`. `isRunDiscVisible` (`:1157-1160`) must consult four of them; a single
`clearScanState()` resets all — evidence they are de-facto phase state. Combinations such as
`.running` + `isConfirmingRun` are representable. Confidence MEDIUM (materiality: the flags are
individually well-commented; the win is invalid-state elimination, not line count).

## Skips (completed coverage)
- S08 parallel selection sets — lane assessed and **declined**: three different key types and
  different rebuild semantics; a shared `Selection<Key>` relocates branching. Recorded as coverage.
- S06 four parallel result arrays — lane assessed and **declined** in the view layer (payload
  types are used outside the boundary); driver is the model-layer walk (see F3).
- S01 parallel `Kind` tables, `CarePlan.finding(_:)` linear scan, partial `unitOutcomes` dict —
  lane assessed and declined (≤17 elements; absent-key state deliberate and tested).

## Audit log
- Census + mechanical partition complete. 285/285, 0 unassigned, 1 collision resolved.
- Batch 1 dispatched: S01, S05, S06, S08, S09.
- S01, S06, S08 returned and were coordinator-validated. **S05 and S09 FAILED — account
  monthly spend limit**, not a code or brief problem.
- Lane rejected a false premise in the S08 brief: `ApplicationsManagerView` is 616 lines, not
  the 1687 asserted by `CLAUDE.md` (stale doc — separate defect, see Cross-cutting).
- S02 audited inline by coordinator (F7). S05 retried as a single probe.

## Cross-cutting patterns
- 13 view models each hand-roll a `Phase` enum; 11 use a generation guard. The two without are
  `HomebrewViewModel` and `ProtectionPrivacyModel` (`scan()` guards re-entrancy by phase, but
  `remove()` at `:170` appears unguarded → a removal landing mid-scan is overwritten by the
  finishing scan's pre-removal counts). Lead for S11.
- `CLAUDE.md` line-count claims are stale (ApplicationsManagerView 1687 → 616). Doc defect.
- Two `.claude/worktrees/` copies of the whole repo shadow every grep. Not audited (not built).

### F8 — S05/S16 — one file emitted twice under two categories (nested scan roots)
ACCEPTED, HIGH. Verified at source: `SystemPathProviding.swift:97-99` composes
`caches = ~/Library/Caches`; `:106-107` emits `ms-playwright`/`Cypress` as `.webDevJunk` roots;
`:117` emits `~/Library/Caches` itself as `.userCache`. `FileScanner.swift:542` walks
`for root in roots` and `:675-683` tags `category: root.category` with no cross-root dedupe.
Chain: `ScanResult.totalSize` double-counts → per-category tallies (attributed by
`file.category`) cannot agree with membership (keyed by `file.url`) →
`CleanupManagerStore.swift:118` first-wins index makes a WebDev row debit User Caches →
`SmartScanReviewManager.swift:769-774` `tally.selected >= tally.total` renders the whole
category checked. Lane correctly refuted half the original hypothesis: size drift is NOT
possible (single immutable snapshot). Generalization assigned to S16. Confidence HIGH.

### F9 — S05 — three disagreeing encodings of "safe to auto-remove"
ACCEPTED, HIGH. `ScanCategory.swift:70-71` returns false for `.mailAttachments`/`.iosBackups`;
`CleanupGroup.swift:27-28` includes both in `systemJunk.categories`; `SystemJunkView.swift:168`
Review calls `selectOnly(categories: Set(group.categories))` → opens pre-checked; `:173` Clean
removes them with no selection. Third encoding: `ScanSelectionSeed.isPreselectable`. Confidence HIGH.

### F10 — S09 — `availableUpdates` is both derived and authoritative
ACCEPTED, HIGH. `AppUpdaterViewModel.swift:390` derives it but applies `declined` **only** to
`brewRows`, never to `directUpdates`; `:249` `skip()` mutates the derived list directly. So
skip(direct update) → next `setHomebrewOutdated` rebuild re-adds it → row is in Available AND
Skipped simultaneously; `clearSkip` then appends a duplicate `id` into a `ForEach`. Existing
tests cover both halves but never interleave them, which is why it escaped. Confidence HIGH.

### F11 — S09 — two brew-invoking entry points never enter a busy phase
ACCEPTED, MEDIUM. `requestUninstall` (:240-266) and `previewCleanup` (:308-319) run brew but
never set `phase`, while all UI re-entrancy defense is `.disabled(isBusy)`. Yields two
concurrent brew processes and a confirmation sheet whose destructive button is inert
(`confirmUninstall` early-returns without clearing `pendingUninstall`). Confidence HIGH on
mechanism, MEDIUM on frequency.

### REFUTED — coordinator lead: "HomebrewViewModel lacks a generation guard"
**My lead was WRONG.** Verified: `HomebrewViewModel.swift:170-172` and `:215` show
`guard !isBusy` immediately followed by the phase write with **no suspension point between**;
the class is `@MainActor` and a same-actor async call does not yield. The phase transition
already closes the window a generation token would guard. Being 1 of 2 view models without one
is not evidence of a defect. Recorded as a coverage result, not a finding.
Separately CONFIRMED as a narrow bug (not a representation issue): `:231` post-upgrade
`try? reloadOutdated` keeps a pre-upgrade list on failure and pushes it into the Updater.

### F12 — S11 — `ProtectionPrivacyModel`: phase is both UI state and mutual exclusion
ACCEPTED, HIGH. Coordinator-verified `:170-184`: `remove()` has **no** guard, writes
`phase = .removing` (erasing an in-flight `.scanning`), then on success calls `await scan()` —
which passes `guard phase != .scanning` (`:59`) *because* phase is `.removing`. Two concurrent
scans result; `scan()` publishes `browsers/counts/itemsByKey` unconditionally at `:73-76`, so a
superseded pre-removal snapshot can land last and permanently restore deleted rows in the UI
(nothing re-triggers a scan; both entry points gate on `.idle`). Fix: operation token, exactly
as the sibling `PrivacyViewModel.swift:82` already does. Confirms + extends coordinator lead.
Confidence HIGH.

### F13 — S11 — `PrivacyViewModel`'s per-cell count pipeline is dead
ACCEPTED, HIGH. Coordinator grep confirms every production `count(for:)`/`totalCount(...)`
resolves to `ProtectionPrivacyModel.swift:89` / `BrowserPrivacyInspector.swift:34`
(`ProtectionManagerView.swift:203`). The only callers of `PrivacyViewModel`'s versions are
`PrivacyViewModelTests.swift:664-674`. `BrowserDataCounter` is referenced in app code from
exactly one place — `PrivacyViewModel.swift:533` — feeding the dead pipeline. Not merely dead
storage: `:315` awaits the counter once per (browser × category) **inside the preview loop**,
doubling that scan's async I/O for a value nothing reads. Already drifting (failure path
`:356-363` resets siblings but not `countsByBrowserCategory`). Confidence HIGH.

### DECLINED — S11 — merging the two privacy models
Lane assessed and declined; coordinator concurs. The split is intentional and documented
(`ProtectionPrivacyCategory.swift:6-10`, `ProtectionDashboardViewModel.swift:26`) and the two
serve different surfaces (path/size clearing vs SQLite row removal). Recorded as coverage.
Deleting F13 makes the boundary cleaner without merging: one model owns bytes, one owns counts.

### F8 (ELEVATED by S16) — nested roots are a structural hazard with precedent
Coordinator-verified prior art: `SystemPathProviding.swift:184-186` documents the *same*
failure mode ("double-counts the same files via path aliasing") already hand-patched for the
boot-volume trash firmlink. So this hazard has been hit before and solved for exactly one known
pair; ms-playwright/Cypress is a second unmitigated instance. S16 measured **12,857 files /
~2.07 GB** emitted twice on this machine. `ScannedFile.category` is documented as a function of
"which root the file lived under" (`ScannedFile.swift:7-8`) but is really a function of
(file, root) with no total order. Preferred fix (S16, coordinator concurs): deepest-root-wins
precedence folded into each root's existing `PreparedExclusions` before the walk — reuses the
machinery already in the loop, costs nothing per file, and is strictly *faster* than today
(overlapping subtrees walked once). Rejected alternatives: scan-wide `Set<URL>` dedupe (puts
documented "costs seconds" hashing into the hot walk); pruning the root list (loses either the
`.webDevJunk` classification or the rest of `~/Library/Caches`). Confidence HIGH.

### F14 — S16 — an exclusion API whose convenience overload warns against itself
ACCEPTED, MEDIUM-HIGH. Coordinator-verified `FileScanner.swift:247-253`: the `[String]`
overload's own doc says "anything running per enumerated file should build one once and use the
overload above" — and `WebDevArtifact.swift:50-52` calls exactly that overload, in a function
whose comment (`:31-33`) states it "runs over every cached file in a category that reaches
hundreds of thousands of them". Per-file callers: `CleanupManagerModel.swift:267`,
`ScanSelectionSeed.swift:56`. Second violator: `SystemJunkScanner.swift:127-133` rebuilds inside
`files.filter`. Fix: delete the `[String]` overload so `PreparedExclusions` is the only currency
— removes an API form rather than adding one, and converts a comment-enforced invariant into a
compiler-enforced one. Confidence HIGH on mechanism; MEDIUM on magnitude (lane explicitly did
NOT profile the split between `PreparedExclusions.init` and the scan — must be measured before
selling as a perf fix).

## PRIORITY RANKING (15 validated findings; 11/27 subsystems reviewed)

**Tier 1 — correctness, ship first (independent of each other):**
1. **F8** nested-root double emission (S16/S05). Widest blast radius: corrupts totals, tallies,
   and the "all checked" render. Has precedent. Fix is contained to `FileScanner.swift`.
   *Prerequisite for F-Cleanup-tallies: fixing F8 restores the "one URL → one file" premise the
   incremental tally maintenance already assumes, so do it FIRST.*
2. **F9** three disagreeing "safe to auto-remove" encodings. Pre-checks iOS backups. Safety
   model. Independent of F8.
3. **F12** ProtectionPrivacyModel operation token. Self-contained, one file, sibling model
   already shows the pattern.
4. **F6** select-all ignores search filter. Destructive scope. Contained.
5. **F10** availableUpdates dual-writer. Contained to one file, removes code.

**Tier 2 — real defects, smaller reach:**
6. **F5** extensions batch state. 7. **F11** Homebrew busy-phase gaps. 8. **F4** My Clutter
stray-selection gate (remedy is a product call). 9. **F13** delete the dead count pipeline
(pure deletion; also a preview-scan speedup).

**Tier 3 — representation cleanups, no known live defect:**
10. **F1** derive `CareFinding.kind` from payload (mechanical, compiler-guided, 116 sites).
11. **F3** single four-category builder (do AFTER F8; both touch scan-result shape).
12. **F14** delete the `[String]` exclusion overload (measure first).
13. **F2** lane-positional app discovery. 14. **F7** SmartScan lifecycle flags.
15. Homebrew `:231` post-upgrade `try?` (narrow bug fix, not a representation change).

**Best first slice:** F8 alone. It is the only finding other findings depend on, it is confined
to one file, existing `FileScannerTests` already pin sibling-root behaviour (the nested case is
precisely the gap), and it makes the scan strictly faster.

## STATUS: INCOMPLETE — 11/27 subsystems reviewed
Reviewed: S01 S02 S05 S06 S08 S09 S11 S16 (+S12/S13/S14 partial via prior session knowledge —
NOT counted as reviewed). **Outstanding (16): S03 S04 S07 S10 S12 S13 S14 S15 S17 S18 S19 S20
S21 S22 S23 S24 S25 S26 S27.** The audit-the-audit passes (coverage, duplication/ownership,
materiality, schema completeness, dependency ranking) have NOT been run as independent fresh
passes; the ranking above is coordinator-authored and unvalidated by a second pass.

## COVERAGE COUNT CORRECTION
Earlier status lines said "11/27 reviewed". That was wrong and internally
inconsistent with the same paragraph, which noted S12/S13/S14 were partial via
prior-session knowledge and "NOT counted as reviewed". Counting them anyway
inflated the figure. **Fully reviewed: 8 subsystems** (S01 S02 S05 S06 S08 S09
S11 S16). **Outstanding: 19** (S03 S04 S07 S10 S12 S13 S14 S15 S17 S18 S19 S20
S21 S22 S23 S24 S25 S26 S27) — not 16.

### F15 — S13 — `failureNeedsFullDiskAccess` is a boolean beside `Phase.failed`, and goes stale
ACCEPTED, MEDIUM-HIGH. Coordinator-verified: the flag is written in exactly two places —
`PerformanceViewModel.swift:255` (cleared at the top of `run(_ task:)`) and `:290` (set in
`perform`'s catch). `dismissResult()` (`:526-528`) is two lines and does **not** clear it. Six
other `.failed` producers never touch it. `PerformanceView.swift:90` reads it independently of
the failure message, so: FDA failure → Dismiss → a *different* failure (login-item toggle, agent
removal) renders that failure's message under an "Open Full Disk Access Settings" button that
cannot fix it. Fix: move the recovery into the case — `.failed(message:needsFullDiskAccess:)`.
Seven construction sites. Confidence HIGH on reachability.

### F16 — S13 — `runMaintenanceScripts` duplicates `perform`; two result fields shadow `taskResults`
ACCEPTED with a correction. Verified: `ramResult`/`maintenanceOutput` (`:50-51`) are read in
production **only** by `finishTask` at `:259`/`:262` — no view reads either (grep over
`VaderCleaner/` returns declarations, assignments, and those two lines). The lane called them
"write-only in production", which is imprecise: they are real plumbing between the two legacy
methods and `finishTask`, just never rendered. The substance stands — three sources of truth for
one task's result line, and `finishTask`'s `guard phase == .ready` (`:300`) exists only to paper
over the legacy methods having already resolved `phase`. Lane correctly declined a
command/registry over the catalog (six fixed kinds, closures already injected per kind).
Confidence HIGH on the duplication; MEDIUM on the RAM half (genuine special case).

### DECLINED — S13 — `run(_ tasks:)` / `workingTitle` / `isRunningBatch`
Lane found the contradictory combination representable but **could not find a suspension point
exposing it**, and explicitly declined to recommend deleting the flicker guard because the
redundancy argument rests on Swift's same-actor async call convention — "too fragile a basis for
deleting a flicker guard". Coordinator concurs; this is the same reasoning that refuted the
Homebrew generation-guard lead. Recorded as coverage.

### DECLINED — S14 — health-status derivation is shared, not duplicated
Lane traced all three surfaces to one function pair (`HealthMonitorViewModel.macHealthStatus` /
`displayedHealth`); `MenuBarViewModel` forwards, and the forwarding is pinned by
`HealthMonitorViewModelTests.swift:529-536`. `CareVerdictEngine` uses it as a *base* then applies
finding-severity caps — a different concern. This refutes a cross-cutting suspicion I had carried
since the first census. Recorded as coverage.

## STATUS
Reviewed: 9 of 27 (S01 S02 S05 S06 S08 S09 S11 S13+S14 S16). In flight: S04 S07 S10 S15.
Findings: 17 accepted, 12 implemented + verified, 5 open (F3 F7 F14 F15 F16).

### F19 — S10 — manual definitions refresh snapshots and restores `phase` unconditionally
ACCEPTED, HIGH. Verified `MalwareViewModel.swift:346-356` + `:377-378`: `resumePhase = phase`
guarded only against `.failed`, restored with no check the slot still holds it. Update is live
during `.removing` (`isScanningPhase` excludes it), so a refresh started mid-removal captures
`.removing` and — when freshclam (network) outlasts the local XPC delete, the likely ordering —
writes `.removing` back over `.done`. Tile pins to "Removing Threats…" with no controls and
`malwareSettled` never turns true. Fix: give the on-demand refresh its own field; `.updatingDatabase`
stays for the in-scan step that genuinely is one.

### F20 — S10 — `cancel()` resets from any phase; `.removing` has no owner
ACCEPTED, HIGH. Verified `MalwareViewModel.swift:154-165`: bumps `scanGeneration`, cancels
`scanTask`, writes `phase = .idle` — neither token governs a removal. `removeThreats` (`:288-300`)
writes its terminal phase after its await **unguarded** (the scan path guards at five points).
Start Over during a removal therefore shows the intro while the helper permanently deletes files,
then the dismissed section re-materialises when the delete lands. Remedy (disable vs token) is a
product call — but a token must NOT drop the terminal write: the files are already gone and the
count must still be reported.

### F21 — S04 — ten `*ReviewLookups` boxes are an identity round-trip, and one is read before it is filled
ACCEPTED, HIGH. Five screens key their box by exactly the `ManagerItem.id` the selection set
already stores, so `isSelected` reduces to `selection.contains(id)`. Seven hand-roll a
(count, Σbytes) pair the view model already memoizes (`sizeTable`/`freeableBytes`/`selectionCount`).
Two screens in-tree already do without a box. **Live defect coordinator-verified**: `footer`
(`SmartScanReviewManager.swift:336-337`) renders OUTSIDE the `sections == nil` branch and `:708`
calls `selectionSummary?()` unconditionally, before the detached build fills the box — so My
Clutter (pre-seeded duplicates) shows "N Items Selected · 0 bytes" for the whole loading window.
The per-file comment "read on the main actor once that build has finished" is therefore false.

### F22 — S04 — `loadItems != nil` silently empties `ManagerCategory.items` for three consumers
ACCEPTED, MEDIUM (latent, no live bug). Unstated three-way coupling enforced nowhere; the author
already patched one site (`:582-584`) for exactly this. Fix: explicit `itemCount` defaulting to
`items.count`.

### DECLINED — S04 — 20 closure params → discriminated union; `ManagerItem` flag combinations
Lane grepped every construction site: read-only mode already collapses to one flag and no caller
mixes it with selection closures; `usesFileIcon`/`usesThumbnail` never co-occur, every `iconPath`
setter sets `usesFileIcon`, `indentLevel > 0` rows always have empty children. Unreachable, inert.
Refutes two of three coordinator leads. Recorded as coverage.

## FINAL STATUS (context-exhausted handoff)
Reviewed: 12 of 27 — S01 S02 S04 S05 S06 S08 S09 S10 S11 S13+S14 S15 S16. S07 in flight.
Unreviewed (14): S03 S12 S17 S18 S19 S20 S21 S22 S23 S24 S25 S26 S27 (+S07 pending).
Findings: 25 accepted / 12 implemented + verified / 13 open.
NOT DONE: audit-the-audit passes; validated dependency ranking across all 25.

### F23 — S07 — `ancestryChain` re-derives tree structure by exhaustive identity DFS per drill-in
ACCEPTED. Verified `DiskScannerViewModel.swift:163-172`: per child it checks `===` then recurses
into that child's ENTIRE subtree before advancing. Both real call sites pass a direct child.
Child order is filesystem enumeration order; display order is size-sorted, so which siblings get
fully walked is unrelated to what was clicked — on the main actor, per click, on million-node
trees. Fix: descend by URL prefix, keep the terminal `===` for cross-scan rejection. HIGH.

### F24 — S07 — drill-in cursor stored outside the phase that owns the tree
ACCEPTED, LOW priority — lane could NOT construct a reachable divergence and said so. Verified
`startScan` clears `navigationPath` but not `forwardStack` (`:374-378`); safe today only by an
accident of UI routing. Honest minimum: add `forwardStack.removeAll()`. MEDIUM.

### F25 — S20 — "have I shown this recently" re-derived in six monitors, one has none
ACCEPTED. Coordinator-verified: `VolumeMountMonitor` has ZERO rate-limiting (grep for
cooldown/lastFired = 0 hits) — a multi-partition drive fires one banner per partition, and the
"connected" branch lacks the `isExternal` gate the branch two lines below applies, so mounting a
.dmg fires it. Shipped copy (`SettingsNotificationsTab.swift:96`) promises a global "no more than
once every few minutes" rule enforced only inside one of six monitors. HIGH on facts; the shared
limiter is optional vs two point fixes.

### F26 — S20 — `AppUpdatesMonitor` memoizes a notification it may never have delivered
ACCEPTED, HIGH. Coordinator-verified `AppUpdatesMonitor.swift:85-86`: `lastAnnouncedCount = count`
runs unconditionally after `dispatcher.send…`, and `UNUserNotificationCenter.add` silently drops
when unauthorized. Denied user → count persisted anyway → after granting permission via the route
the Notifications tab offers, `guard count != lastAnnouncedCount` suppresses it across relaunches
until the number changes. Persisted, so it survives restart. Same for toggling the pref off/on.

### F27 — S19 — `menuBarShowsReading` is a live writable preference nothing reads
ACCEPTED. Coordinator grep: **0** production readers outside `PreferencesStore`. Superseded by
`menuBarReading`, but kept as a full tracked property with a public setter, so every disagreeing
combination is reachable and meaningless. The migration already reads the raw key from `defaults`,
bypassing the property — proof it isn't load-bearing. Delete it; keep the key string.

### DECLINED — S19 — PreferencesStore preference registry
Lane refuted the coordinator lead outright: only 2 of ~26 preferences carry a side-effect handler;
monitors pull at evaluate time rather than subscribing per-preference. It also CHECKED the
completeness invariant that would justify a registry (all 26 Key entries covered by
`restoreDefaults`) and found it holds. Recorded as coverage.

### CONFIRMED CLEAN — S19 — `restoreDefaults()` store separation
`WelcomeStore` is not among the five stores `SettingsRestore.restoreAll` reaches, namespaces are
disjoint, and two near-misses were specifically cleared (legacy `smartScan.enabledModules` made
unreachable; `preferences.appUpdates.*` correctly untouched despite sharing the prefix).

## STATUS AT CONTEXT EXHAUSTION
Reviewed + validated: 15 of 27. In flight (unvalidated): S17+S03, S18+S12, S21+S22+S23, S24-S27.
Findings: 27 accepted / 12 implemented + verified / 15 open.

### F28 — S18 — `isReviewing` is view state mirrored into the model and never resyncs
ACCEPTED, HIGHEST USER IMPACT SO FAR. Coordinator-verified: `setReviewing` has exactly ONE
writer (`SmartScanView.swift:94`, an `onChange`) inside a view whose lifetime is `.id(selectedSection)`
-scoped (`ContentView.swift:248`), so a section switch destroys it WITHOUT firing. `isReviewing`
stays true → `isRunDiscVisible` false → and `FloatingRunOverlay.swift:47` is the **only** caller of
`requestRun()` in the app. Repro: results → open a Review → switch section → return. The Fix disc
never appears and the scan cannot be run until a Review is reopened/closed or Start Over.
**This sharpens F7, which I authored and labelled "no known live defect" — I was wrong.**

### F29 — S12 — "what privacy data still exists" is represented three times
ACCEPTED. Two sibling models (`privacy` tiles / `protectionPrivacy` manager) plus a view-local
`removedPrivacyTiles` negation set; `clearData(for:)` updates none of the others. Clear on the
dashboard → the manager still lists the data; clear in the manager → the dashboard still offers a
"cannot be undone" confirmation for data already gone. Lane refuted the coordinator's stated lead
(manager/sheet combinations are unreachable; the set does NOT outlive Start Over) and found this
instead. MEDIUM severity (phantom rows, redundant confirmation — not data loss).

### F30 — S27 — the generated Xcode project has three writers and no arbiter
ACCEPTED. `VaderCleaner.xcodeproj` is tracked; `ci.yml:2-3` states CI regenerates rather than
trusting it, and there is **no** `git diff --exit-code` check anywhere. Meanwhile `project.yml:169-170`
instructs the developer to tick a scheme box in Xcode, which writes to the *tracked* `.xcscheme` —
a change CI silently normalizes away, and the exact divergence that breaks `WelcomeStoreTests` via
the argument domain (already defended three times in prose). Lane verified the artifacts are in
sync TODAY (all 518 .swift files have PBXFileReference). Fix: untrack, or pin xcodegen + add the
diff check. Lane leaned untrack and said why.

### F31 — S24 — 16 hand-written helper-protocol spies, 7 byte-identical
ACCEPTED, narrowed by the lane itself: one shared spy would NOT serve all 16 (recorders genuinely
differ), but seven are unconditional copy-paste of nine empty methods (~127 lines of stub bodies no
assertion reads). Scope to those seven. `CLAUDE.md:136-139` already names the cost.

### F32 — CROSS-CUTTING — `CLAUDE.md` carries multiple stale factual claims
ACCEPTED. Lane audited its concrete assertions; **coordinator corroborated three independently
from this session's own measured runs**:
- "2137 tests" → lane counted 2308. My runs: 2292 executed with 2 suites skipped; lane counts those
  suites at 8 methods each = 16. 2292 + 16 = **2308**. Exact match. Stale by 171.
- "~94 warnings" → I measured **99** at baseline, 100 mid-session. Stale.
- "379 of 448 files" (CLAUDE.md:76) vs "250 files" (.swiftformat:6) — two different stale baselines
  for the same fact; my swiftformat runs report **518** in scope. Both wrong.
- "ApplicationsManagerView at 1687 lines" → 616. Known.
- One the lane flagged that my data RESOLVES in CLAUDE.md's favour: it called out "~70s" as
  contradicting `ci.yml`'s "~25s". My four local full runs measured 65.9s / 72.8s / 73.9s / 74.8s —
  CLAUDE.md is right for a local run; the CI figure describes different hardware and 16 fewer tests.
  Recorded so a future reader does not "fix" the correct number.

## FINAL STATUS
Reviewed + validated: 18 of 27. Unvalidated reports waiting: S17+S03, S21+S22+S23.
Findings: 32 accepted / 12 implemented + verified / 20 open.
NOT DONE: audit-the-audit passes; validated dependency ranking across all 32.

### F33 — S23 — `ProcessLineStreamer` returns a bare Int32; the cancel branch that expects a throw is dead
ACCEPTED, HIGH. Coordinator-verified from source: `ProcessLineStreamer.swift:109-119` returns
`process.terminationStatus` on the cancel path — its own comment says "the function returns through
its normal path" — so it NEVER throws `CancellationError`. `HomebrewViewModel.swift:409-411`'s
`catch is CancellationError` is therefore **unreachable in production**; the live path yields the
signal number and falls into `recordFailureIfNeeded`, so pressing Cancel shows
"brew upgrade exited with status 15" as an error. The branch is kept alive only by
`BrewTestDoubles.swift:63-65`, which models a hang as `Task.sleep` — and Task.sleep DOES throw.
**Stub-fidelity defect: the double and the real runner have contradictory cancellation contracts,
and the test passes against semantics production does not have.** Fix: throw CancellationError
before returning when `Task.isCancelled`, which makes the already-written branch real.

### F34 — S23 — two subprocess runners, contradictory policies for blocking I/O
ACCEPTED, MEDIUM. `DefaultBrewRunner.swift:103-116` documents at length why blocking
`waitUntilExit`/`readToEnd` must NOT run on the cooperative pool ("a forward-progress hazard"),
then `runStreaming` delegates to `ProcessLineStreamer.swift:95-111`, which does exactly that via
`Task.detached`. Consequence is already recorded in the repo: a stuck streamer "used to wedge the
entire xcodebuild test session rather than fail" — the signature of pool exhaustion. Bounds the
known grandchild leak's blast radius; does NOT attempt to fix the leak. Lane sized it honestly
(one thread per run, few concurrent runs; the sharp cases are the leaked reader and the suite).

### CONFIRMED CLEAN — S21 — welcome resume-by-case-name
Lane verified the full invariant: persistenceKey storage, unknown-name degradation, markCompleted
and reset both clearing, one move funnel, and the launch-argument replay hazard already handled by
`WelcomeUITests.launchAsFirstRun`. Refutes coordinator lead (c) on duplicated onboarding state:
three DIFFERENT facts, one explicit documented coupling. Recorded as coverage.

## AUDIT CLOSED AT CONTEXT EXHAUSTION
Reviewed + validated: 19 of 27. Unvalidated report waiting: S17+S03 (app shell + SmartScan UI).
Findings: 34 accepted / 12 implemented + verified / 22 open.
NOT DONE: audit-the-audit passes; validated dependency ranking across all 34.

### F35 — S17 — `attach()` bypasses the disc panel's documented single decision point
ACCEPTED. Coordinator-verified: `ScanDiscWindowController.swift:96` calls
`window.addChildWindow(panel, ordered: .above)` unconditionally, while `:130-131` declares
`applyDiscVisibility()` "the single place either input is applied". So on every attach (first
launch; window close/reopen from the menu bar) the panel orders in regardless of
`contentWantsDisc` and `isSuppressed` — the precise case `ContentView.swift:280-283` was written
to prevent, and which setting `isSuppressed` first cannot prevent because its `didSet`
early-returns while `panel` is nil (`:133`). Two-line fix: end `attach()` with
`applyDiscVisibility()`. Severity MEDIUM (panel is transparent; may be latent, not a visible flash).

### F28 — CROSS-LANE CORROBORATION
S17+S03 independently rediscovered the stuck-`isReviewing` defect with no knowledge of the
S18+S12 lane's report, reaching the same mechanism (`.id(selectedSection)` teardown, no `onChange`
on removal, `clearScanState()` the only other writer). **Two blind lanes converging is the
strongest validation signal produced in this audit.** S17 also added a second reachable invalid
state on the same fact: `review != nil && managerKind == nil` mounts a blank full-screen manager
with no Back button, unreachable today only because `openReview` happens to write both. It flagged
one trap for the fix: moving ownership to the view model changes return-to-section behaviour
(the Review re-opens), so `managerKind` must be seeded or the host mounts an empty manager.

### DECLINED — S17 — ScanCoordinating projections; SectionPrewarmQueue wedging
Lane checked all seven `ScanCoordinating` conformers and every `.idle` arm; projections are sound,
Protection's asymmetric `.working` omission is deliberate with an existing escape hatch. The
prewarm queue cannot wedge: `isDraining` and its `defer` are registered with no await between,
steps are non-throwing. **Both were coordinator leads; both refuted.** Recorded as coverage.

## AUDIT COMPLETE — ALL 27 SUBSYSTEMS HAVE REPORTS
Reviewed + coordinator-validated: 20 of 27 (all 5 final-batch lanes landed; S17+S03 validated).
Findings: 36 accepted / 12 implemented + verified / 24 open.
STILL NOT DONE: the audit-the-audit passes, and a validated dependency ranking across all 36.
