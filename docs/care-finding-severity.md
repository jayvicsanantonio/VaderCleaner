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
    /// The finding is large relative to what this kind usually turns up.
    case magnitude
    /// Free space is short enough that reclaimable findings matter more.
    case diskPressure
    /// This kind was cleaned in a recent Run and has come back.
    case regrowth(since: Date)
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

    /// The context for surfaces with no history to consult.
    static let none = CareSeverityContext(health: nil, receipts: [], now: .distantPast)
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
score = clamp(magnitudeWeight * magnitude + pressureWeight * pressureBoost + recencyWeight * recency)
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

**Whitelist — regrowth only escalates for `duplicates`, `appLeftovers`,
`installers`, and `downloads`.** For `junkCleanup` regrowth is the system
working as designed (macOS rebuilds its caches; the copy already says so), and
treating a rebuilt cache as an escalating problem would be alarming and wrong.
Junk still reports the `.regrowth` signal for copy purposes — the note is
useful — but its score contribution is zero.

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

**Phase 1 — magnitude. Shipped.** `CareSeverity`, `CareSeverityEngine`,
`CareSeverityContext` (health only — `receipts` and `now` arrive with the code
that reads them), both disk rules, the score, the ranker context parameter,
the verdict cap, and the `SmartScanViewModel` wiring. No persistence, no
history reads. 18 `CareSeverityEngineTests`, 4 added `CarePlanRankerTests`,
3 added `CareVerdictEngineTests`; full suite 2054 green, 0 lint errors, clean
Swift 6 build with 0 warnings.

**Phase 2 — memory.** Regrowth detection against `CareHistoryStore.receipts`,
the whitelist, the recency term, `severityNote`. Wire the context in
`SmartScanViewModel` from the injected history store. This is the phase that
makes the receipt log earn its keep.

**Phase 3 — declined findings (optional, not scoped here).** "You have left
Similar Photos unselected six scans running, so stop leading with it" needs
persistence that does not exist yet — a per-kind declined counter. Worth doing,
but it is a new store and a new privacy question (it is a record of what the
user chose not to do), so it should be specced separately rather than smuggled
in behind a scoring change.

## Tests

TDD order. Every one of these is a pure-function test — no fixtures on disk, no
main actor.

`CareSeverityEngineTests`
- `test_baseTier_matchesTheKindsUrgency_withEmptyContext`
- `test_lowDiskSpace_at99Percent_escalatesToCritical`
- `test_lowDiskSpace_at91Percent_staysAttention`
- `test_diskCriticalThreshold_isTheHealthMonitorConstant_notACopy`
- `test_largePreApprovedFinding_underDiskPressure_escalatesToAttention`
- `test_optInFinding_underDiskPressure_doesNotEscalate`
- `test_smallFinding_underDiskPressure_doesNotEscalate`
- `test_appUpdates_stayAttention_atEveryCount`
- `test_score_isMonotonicInBytes_forSizedFindings`
- `test_score_separates40GBFrom6GB_moreThan200MBFrom100MB`
- `test_countFindings_scoreSaturatesAtNotableCount`
- `test_regrowth_firesWithinThirtyDays_atHalfTheClearedCount`
- `test_regrowth_doesNotFire_belowHalfTheClearedCount`
- `test_regrowth_doesNotFire_pastThirtyDays`
- `test_regrowth_onJunk_reportsSignal_butScoresZero`
- `test_regrowth_onLeftovers_escalatesToAttention`
- `test_severity_isDeterministic_forTheSameInputs`

`CarePlanRankerTests` (additions)
- `test_rankedWithoutContext_matchesTheLegacyOrder`
- `test_regrownFinding_outranksALargerQuietOne`
- `test_criticalDisk_leadsTheFeed_aboveLargerSpaceFindings`

`CareVerdictEngineTests` (additions)
- `test_criticalSeverityFinding_capsTheVerdictAtCritical`
- `test_verdictCaps_stillOnlyLower_neverRaise`

`CareFindingCopyTests` (additions)
- `test_severityNote_isNilWhenNoSignalFired`
- `test_severityNote_prefersRegrowthOverDiskPressure`
- `test_severityNote_coversEverySignalCase`

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
