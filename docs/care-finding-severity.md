# Care finding severity

Spec for making Smart Scan's recommendation strength a function of **magnitude
and history** rather than a switch on finding kind.

## The problem

`CareFinding.urgency` (`VaderCleaner/CareFinding.swift:201`) is a hardcoded
`switch kind`. Three consequences:

- **No magnitude.** 3 available updates and 40 rank identically. A disk at 91%
  full and one at 99% rank identically. 200 MB of junk and 40 GB rank
  identically. The only magnitude threshold in the system is
  `CareVerdictEngine.safeJunkCapBytes` (5 GB).
- **No memory.** `CareHistoryStore` records `lastScanDate`, a lifetime freed
  total, and 24 `CareReceipt`s. Nothing reads them for ranking — `lastScanDate`
  and `receipts` are read only by `SettingsGeneralTab.swift:204`, to decide
  whether the *Clear History* button is enabled. The store's own doc comment
  calls itself "the memory behind 'since last scan' copy"; that copy does not
  exist.
- **Ordering is raw bytes.** `CarePlanRanker` sorts critical → bytes descending
  → kind declaration order, so the only signal separating two space findings is
  which number is bigger.

## What this does not change

- `RecommendationUrgency` (`VaderCleaner/SectionRecommendation.swift:10`) is
  shared with five other section dashboards through
  `SectionRecommendationSelector`. Its cases and meaning stay exactly as they
  are. This spec adds a score *alongside* the tier; it does not replace it.
- `CareActionability` and the three-zone safety model are untouched. Severity
  decides how loudly a finding leads, never what Run is allowed to do with it.
  A finding that scores 1.0 is still opt-in if it is the user's data.
- The per-kind base tier is preserved, so every existing assertion in
  `CareFindingTests` (`test_urgency_*`) stays green. Severity only escalates
  from that base, under explicit rules.

## Blast radius

`finding.urgency` has three readers:

| Site | Use |
| --- | --- |
| `CarePlanRanker.swift:14` | critical-leads check |
| `CarePlanFeedView.swift:433` | critical tile styling |
| `CareFindingTests.swift:177` | per-kind tier assertions |

`CarePlanRanker.ranked(_:)` has two call sites, both in `SmartScanViewModel`:
the memoized feed order (`:527`) and the Run queue (`:1122`).
`CareVerdictEngine` has two consumers (`SmartScanViewModel:511`,
`CarePlanFeedView:62`). Small enough to change in one pass.

## Model

Three new types, all `Sendable`, all pure — same shape as
`PerformanceRecommendationEngine`, which is the house pattern for a
deterministic, exhaustively-testable decision core.

```swift
/// Why a finding scored the way it did. Drives both the score and the
/// one-line note under a card's metric.
enum CareSignal: Equatable, Sendable {
    /// Free space is short enough that reclaimable findings matter more.
    case diskPressure
    /// This kind was cleaned in a recent Run and has come back.
    case regrowth(since: Date)
    /// The user has passed on this kind enough times running that the app has
    /// stopped leading with it. The only signal that quiets rather than raises.
    case declined(times: Int)
}

/// How loudly a finding should lead, and why.
struct CareSeverity: Equatable, Sendable {
    /// The existing four-tier urgency, possibly escalated from the kind's base.
    let urgency: RecommendationUrgency
    /// Within-tier ordering weight, 0...1. Blends magnitude with the other
    /// signals, which is the reason this is a score and not just a byte count —
    /// raw bytes are monotonic and would produce today's ordering exactly.
    let score: Double
    /// Signals that fired, in declaration order. Empty is the common case.
    let signals: [CareSignal]
}

/// Everything the engine reasons over besides the finding itself.
struct CareSeverityContext: Sendable {
    let health: CareHealthSnapshot?
    /// Newest last, as `CareHistoryStore` stores them.
    let receipts: [CareReceipt]
    let now: Date
    /// Consecutive Run passes the user has left each kind alone.
    let declines: [CareFinding.Kind: Int]

    /// The context for surfaces with no history to consult.
    static let none = CareSeverityContext(health: nil, receipts: [], now: .distantPast, declines: [:])
}
```

## Rules

### Escalation

The base tier is `CareFinding.urgency` as it stands today. Only these rules
raise it, and nothing lowers it:

1. **`lowDiskSpace` → `.critical`** when
   `HealthMonitorViewModel.diskUsageRatio >= diskCriticalThreshold` (0.95).
   Reuse the existing constant; do not introduce a second threshold. This is
   already what `macHealthStatus` does to the verdict tier — the rule makes the
   *card* lead the feed to match.
2. **Disk-pressure boost (score, not tier)** when the disk is at or above
   `diskWarningThreshold` (0.80) **and** the finding is `preApproved` **and**
   its `reclaimableBytes` exceeds `diskPressureFloorBytes` (1 GB). Signal:
   `.diskPressure`. Opt-in findings never qualify — pressure is not a reason
   for the app to push harder on data it isn't allowed to remove unattended.

   **This was a tier escalation in the first draft of this spec.** It became a
   score boost during Phase 1 for two reasons. Ordering by full `urgency`
   would put every advisory above every space finding — "App updates
   available" would outrank a 40 GB junk find inside the same
   *Fix will handle these* zone, which is wrong. And because the ranker leads
   on `.critical` only, an escalation to `.attention` would have changed
   nothing observable: dead behavior with a test pinning it.
3. **Regrowth (score, not tier)** for a kind in the regrowth whitelist below.

`appUpdates` deliberately stays `.attention` at every count. Distinguishing a
security update from a feature bump needs data `UpdateProbe` does not return;
inventing a proxy for it would be a guess dressed as a recommendation.

### Score

```
raw   = clamp(magnitudeWeight * magnitude + pressureWeight * pressureBoost + recencyWeight * recency)
score = raw * damping(forDeclines:)
```

Weights sum to 1 within each phase, so no phase ships a constant it does not
use. Phase 1 is `magnitude 0.85 / pressure 0.15`; Phase 2 rebalances to make
room for recency. Score is never displayed — it exists only to be compared —
so re-weighting between phases costs nothing.

- **magnitude** — for sized findings, `log10(max(bytes, 1)) / log10(100 GB)`,
  clamped to `0...1`. For count-only findings, `min(1, count / notableCount)`
  where `notableCount` is a per-kind constant (e.g. 10 threats, 20 updates,
  25 login items). Log scaling is deliberate: it keeps 40 GB clearly ahead of
  6 GB while stopping 200 MB and 100 MB from pretending to be a meaningful
  gap.

  **Magnitude orders the feed and never speaks.** An earlier cut raised a
  `.magnitude` signal above 0.9 and rendered it as "Bigger than usual for this
  kind of thing." Two problems, both visible on the first real screenshot: the
  threshold works out to **7.94 GB**, so it fired on four of eight sized cards
  and read as wallpaper; and the copy promised a per-kind comparison the engine
  never made — one global 100 GB ceiling cannot tell a photo library from an
  installer folder, and count kinds saturate at trivially low counts (browsing
  traces at 500 items, so 214,383 and 501 both score 1.0). It was removed
  rather than given a baseline: the card already prints the size, so a badge
  saying "this is big" beside "325.47 GB" adds nothing, and an honest baseline
  would mean inventing per-kind constants with no evidence behind them.
- **recency** — `1.0` when `.regrowth` fired, decaying linearly to `0` over
  30 days since the receipt that cleaned it. `0` when it did not.

Score exists to be blended. If it were magnitude alone it would be monotonic in
bytes and would reproduce today's ordering exactly, which is the point being
fixed.

### Regrowth

For a finding of kind `K`, walk `receipts` newest-first for the first line with
`kind == K` and `itemsProcessed > 0`. Regrowth fires when that receipt is within
30 days of `now` **and** the current finding's `itemCount` is at least half what
that line processed.

Only the **newest** clearing receipt is consulted. An older one describes a
cleanup a later pass already superseded, and walking past it would let ancient
history revive a signal the recent record contradicts.

**Whitelist — regrowth is only detected for `duplicates`, `appLeftovers`,
`installers`, and `downloads`.** `junkCleanup` and `maintenanceDue` are
excluded for the same reason: both are *designed* to recur. macOS rebuilds its
caches, and a tune-up that never came due again would not be routine. Reporting
either as "back since your last cleanup" frames the system working correctly as
a complaint.

The first cut of this got it half right — it excluded those kinds from
*scoring* but still emitted the signal, on the theory that the note was worth
saying. Shipped, that put "Back since your last cleanup." under *Routine
tune-up due*, which is close to nonsense. The carve-out belongs at the signal.

A test pins every whitelisted kind to `movesToTrash`, so nothing the app
escalates on regrowth is something the user can't undo.

## Ranking

```swift
static func ranked(_ findings: [CareFinding], context: CareSeverityContext) -> [CareFinding]
```

Sort key, in order: **critical leads**, then **sized findings ahead of
count-only ones**, then **score descending**, then `kindIndex`.

The sized/count split matters. Bytes measure against a fixed scale and counts
measure against what's routine for a kind; they don't meet on a normalized
number. Without the split, a one-of-one disk advisory (magnitude 1.0) outranks
a real space win of any size below the ceiling — which is how the first
implementation behaved, and it was wrong.

`context` is a defaulted parameter rather than a second overload, so all five
existing `CarePlanRankerTests` and both `SmartScanViewModel` call sites keep
compiling; the view model opts in by passing `CareSeverityContext(health:)`
from the plan it already holds.

## Verdict

`CareVerdictEngine.status(for:)` gains one cap: a finding reporting a disk at
or above `diskCriticalThreshold` caps the tier at `.critical`, so the hero
reads "Your Mac needs help right now" rather than "could use a little care"
while the disk is about to fill.

The cap keys on `CareSeverityEngine.reportsCriticallyFullDisk(_:)`, **not** on
"severity resolves to `.critical`" as first drafted. Threats carry a critical
*finding* urgency by kind, and capping on that would have silently promoted
every malware verdict from `.requiresAttention` to `.critical` — a real
behavior change wearing the costume of a refactor. Because the rule reads the
finding's own payload, `status(for:)` needs no context parameter at all.

## Copy

One addition to `CareFindingCopy`:

```swift
static func severityNote(for signals: [CareSignal]) -> String?
```

Returns `nil` when no signal fired (the common case — no visual change to a
quiet card). Otherwise one plain line under the metric, in the catalog's
existing voice:

- `.regrowth` — "Back since your last cleanup."
- `.diskPressure` — "Worth doing now — your disk is filling up."
- `.magnitude` — "Bigger than usual for this kind of thing."

Highest-priority signal wins; they never stack into a paragraph.

## Phasing

Each phase ships green and is useful alone.

**Phase 1 — magnitude. Shipped** (`600613e`). `CareSeverity`,
`CareSeverityEngine`, `CareSeverityContext`, both disk rules, the score, the
ranker context parameter, the verdict cap, and the `SmartScanViewModel`
wiring. No persistence, no history reads.

**Phase 2 — memory. Shipped** (`4f6acd9`). Regrowth detection against
`CareHistoryStore.receipts`, injected as a `pastReceipts` closure to match how
every other collaborator reaches the view model. The scoring whitelist, the
recency decay, `CareFindingCopy.severityNote(for:)`, and the tile that renders
it. Weights rebalanced to `magnitude 0.60 / pressure 0.15 / recency 0.25`.

Two things fell out of building it:

- The context is **snapshotted on first read** and dropped by
  `invalidateResultsCaches()`, not rebuilt per access. `now` anchors every
  receipt age, so a clock advancing between reads would let the feed quietly
  reorder itself mid-session.
- `CareResultTile`'s red critical edge was reading `finding.urgency` — the
  kind's own tier — so the disk card Phase 1 escalates never got it. It now
  reads severity.

Before this phase the 24-receipt log existed only to enable a *Clear History*
button.

**Phase 3 — declined findings. Shipped.** `CareDeclineStore`, the
`.declined(times:)` signal, multiplicative score damping, the note, and the
Settings clear path.

**What counts as a decline.** A completed Run pass is the one moment the choice
is unambiguous: the plan was on screen, the user chose to act, and this finding
was not part of what they chose. Closing the window or never running tells us
nothing, so neither is counted. Informational findings are excluded — there is
nothing there to decline.

**Only opt-in findings damp.** Opt-in findings are the user's own files, and
passing on them is a standing preference worth respecting. Pre-approved
findings are hygiene the app vouches for — junk, duplicates, updates, and above
all threats — and no amount of passing is a reason to stop raising them. Two
tests pin this: `test_declines_neverDampenPreApprovedFindings` and
`test_declines_neverQuietThreats`.

**Damping is multiplicative, mild, and floored.** `damping(forDeclines:)`
returns 1 below `declineThreshold` (3), then eases to `declineDampingFloor`
(0.5). Multiplicative rather than subtractive so a large declined finding still
outranks a trivial one — the app takes the hint without hiding the evidence.
Declines move the score only: they never change a tier and never remove a card.

**Privacy.** The record is a kind identifier and an integer. No paths, no
filenames, no timestamps — it cannot describe a file the user owns, only which
*categories* of housekeeping they keep skipping. Settings' Clear History wipes
it alongside the receipt log so one action forgets everything the app has
recorded, the confirmation copy says so, and the button enables when either
record is non-empty. `test_countTable_exposesOnlyKindsAndCounts` pins the
stored shape; unknown keys are dropped on load so a retired kind cannot linger
as a count nothing can reset.

**It always shows a note.** This is the only signal that quiets a finding, and
the only one derived from the user's own behaviour rather than the machine's
state. Silently reordering someone's feed based on what they did would be worse
than not doing it, so `.declined` outranks `.magnitude` in note priority.

## Tests

All pure-function tests except the store and the run-choice cases — no fixtures
on disk. Shipped counts:

| Suite | Tests | Note |
| --- | --- | --- |
| `CareSeverityEngineTests` | 37 | new |
| `CareDeclineStoreTests` | 10 | new |
| `CareFindingCopyTests` | 16 | 10 original, 6 added |
| `CareVerdictEngineTests` | 17 | 14 original, 3 added |
| `CarePlanRankerTests` | 10 | 5 original, 5 added |
| `SmartScanViewModelRunTests` | +3 | decline/accept reporting |

Full suite: **2093 green**, up from 2038 at branch point. 0 lint errors, clean
Swift 6 build with 0 warnings.

Three names in this spec's first draft did not survive contact with the code,
for reasons recorded above: `test_regrowth_onLeftovers_escalatesToAttention`
became `test_regrowth_raisesScore_forAWhitelistedKind` (regrowth scores, it
does not escalate tiers); `test_criticalSeverityFinding_capsTheVerdictAtCritical`
became `test_criticallyFullDiskFinding_capsTheVerdictAtCritical` with a
companion `test_threats_stillCapAtRequiresAttention_notCritical` guarding the
distinction; and the Phase 3 damping tests replaced the drafted escalation
tests, since declines damp scores rather than moving tiers.

## Open questions

1. **30-day regrowth window** — plausible, not measured. It is one constant in
   one place, so it is cheap to revise once there is real receipt data.
2. **100 GB score ceiling** — anything above it scores 1.0. Fine for a laptop;
   worth revisiting if external volumes ever enter Smart Scan's scope.
3. **Should severity be stored on `CareFinding`?** No — it depends on context
   the finding does not own, and `CareFinding` is built off the main actor
   before history is reachable. Keep it derived, memoized in the view model
   next to `rankedFindingsCache`, and invalidated by the same
   `invalidateResultsCaches()`.
4. **A decline is inferred, not stated.** For opt-in findings, unselected is
   also the *seeded* state, so running Fix without touching a card is counted
   as passing on it even when the user never really considered it. The
   threshold of 3 is what makes that acceptable: three passes running without a
   single selection is a habit, not an accident. A truer signal would be "opened
   Review and still chose nothing", which needs review-visit tracking this
   phase deliberately does not add.
5. **Damping constants** (threshold 3, step 0.15, floor 0.5) are judgement,
   not measurement — one clause of `damping(forDeclines:)` to revise.
