# Dead Code Report

> **This file is a snapshot and goes stale.** An earlier version of it claimed
> 132 findings, headlined by a file that had already been deleted. Regenerate
> before trusting it, and treat the categories below — not the count — as the
> durable part.

Generated with Periphery 3.7.4, scanning the `VaderCleaner` scheme with test
targets **included** in indexing, so anything a test touches counts as used.

```bash
periphery scan --project VaderCleaner.xcodeproj --schemes VaderCleaner \
  --retain-swift-ui-previews --retain-objc-accessible --retain-assign-only-properties \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=skip-dev-seal
```

**21 findings, all triaged.** Nothing in the current list is a straightforward
deletion — the easy ones have been removed. Verify before acting on any of it.

---

## Do not delete these — they are tool false positives

Periphery cannot see through a protocol requirement whose call sites go via the
**concrete** type rather than the existential. All four of these compile-break
if removed:

| reported | real call sites |
| --- | --- |
| `AppDiscovering.installedApps(includingSystemApps:)` | 32 |
| `AppDiscovering.bundleSize(at:)` | 28 |
| `ExtensionDiscovering.extensions()` | 16 |
| `UnsupportedAppScanning.scan(apps:)` | live in `CareScanEngineLive` |

C-interop structs are the other classic false positive: fields exist for binary
memory layout even when Swift never reads them (`SMCReader`'s key-data structs).

---

## Judgment calls — deliberate, not accidental

**`BrowserDetecting` and `DiskScanning`** — single-conformer protocols never
used as a type. Both say in their own doc comments that they are kept for
symmetry with `FileScanning` and possible future substitution. Note that
`BrowserDetecting`'s rationale is now stale in an instructive way: it claims
tests inject through it, but tests use `DefaultBrowserDetector(existsAt:)` on
the concrete type, and production wraps it in a closure. The closure-injection
pattern superseded it on both sides. Removing them is a design decision.

**`MenuBarViewModel.diskUsedFraction` / `batteryCharge` / `batterySymbolName` /
`batteryStatusColor`** — four unread instance wrappers left over from when the
menu bar showed vitals *tiles* rather than a checklist. Removing them strands
the statics behind them, which carry real tested logic (a battery-percent → SF
Symbol mapping with coverage). Whether that goes depends on whether the battery
tile is coming back.

**`Color.vaderDeepRed`** — one tone of a documented three-colour brand palette.
A design token, not dead logic.

**`LargeOldFilesFailureStage.deleting`** — never constructed;
`LargeOldFilesFailedState` is only ever built with `.scanning`. The enum's
comment states it exists so the shared failed-state view stays usable across
sections.

---

## Noise

Four unused parameters and three test-internal affordances. These are API shape
and test seams — `LoginItem.setEnabled(_:for:)` takes the item its injected
handler doesn't need, which is the seam working as designed.

---

## Previously removed

For reference, the last cleanup pass deleted: `MenuBarViewModel.bootVolumeName`,
`ScanProgressFormatting.threatsScanned` / `appsChecked`,
`CareReceipt.failedLines`, `SmartScanViewModel.isJunkFileSelected`,
`HealthMonitorView.verdictAccent`, `UpdateInstallerLive.log`, and an unused
import in `TestHelpersTests`.

Three of those carried doc comments describing UI that no longer read them,
which is the more useful signal in a report like this: **a dead symbol often
means a stale comment nearby is now lying.**
