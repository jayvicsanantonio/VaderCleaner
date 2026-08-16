# Onboarding

A guided path into VaderCleaner for someone who has never seen this codebase.
Read it top to bottom the first day; after that it's a reference.

`CLAUDE.md` at the repo root is the *rules* — conventions you must follow.
This file is the *map* — what the code is, where to start, and which surprises
are load-bearing rather than bugs. Where they overlap, `CLAUDE.md` wins.

---

## 1. What this app is

VaderCleaner is a native macOS cleaning and optimisation app: it finds junk
files, duplicates, malware, and unused apps, and removes them. It is
**unsandboxed and personal-use**, so it has deep access to the filesystem —
which is exactly why the conventions around deletion and logging are strict.

Three facts shape almost every design decision:

1. **It deletes the user's files.** Everything user-facing goes to the Trash,
   never a hard delete, so a mistake is recoverable. Permanent deletion is
   reserved for regenerable caches and is confirmed in the UI first.
2. **It walks enormous directory trees.** A junk scan routinely visits over a
   million filesystem items. Anything that runs per file is on a hot path.
3. **Some work needs root.** That runs in a separate privileged helper process
   over XPC, never in the app.

Stack: SwiftUI, Swift 6 language mode, deployment target macOS 26.

---

## 2. Get it building first

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

**The `.xcodeproj` is generated.** Never edit it by hand, and never add files
through Xcode's "New File" dialog expecting them to stick. Add the file to the
right directory, then:

```bash
xcodegen generate
```

Build:

```bash
xcodebuild -project VaderCleaner.xcodeproj -scheme VaderCleaner -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run the unit suite (~70 seconds):

```bash
xcodebuild test -project VaderCleaner.xcodeproj -scheme VaderCleaner -destination 'platform=macOS' -only-testing:VaderCleanerTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="skip-dev-seal"
```

That `CODE_SIGN_IDENTITY="skip-dev-seal"` is not decoration. Without it,
`Scripts/sign-dev.sh` seals the app bundle in a way that breaks the test
bundle's format and the run fails with a confusing "bundle format
unrecognized".

### Three things that look like your fault and aren't

- **`DefaultBrewRunnerTests` / `ProcessLineStreamerTests` can hang forever.**
  Not fail — hang. A grandchild process survives `Process.terminate()` and
  keeps its inherited copy of the stdout pipe open, so the reader never sees
  EOF. `pkill -f xcodebuild` and re-run, or pass
  `-skip-testing:` for both (which is what CI does). If you changed
  `ProcessLineStreamer` or `DefaultBrewRunner`, you **must** run them locally —
  CI skips them, so developer machines are the only coverage.
- **UI tests can't run from a terminal here.** The XCUITest runner is
  signal-killed before it establishes its XPC connection. They compile fine.
  Run them from Xcode.
- **A `TEST FAILED` whose summary says 0 failures** usually means the first
  test session crashed and was retried. Look for a doubled `Testing started`
  in the log.

---

## 3. Read the code in this order

Don't start at `VaderCleanerApp.swift` and try to read outward — you'll drown.
Read **one feature top to bottom** first, then generalise.

### Step 1 — the shape of a feature: Cleanup

Read these four files in order. They're one vertical slice, and every other
section is built the same way:

| file | what it teaches |
| --- | --- |
| `SystemJunkScanner.swift` | how a scan finds things (off the main actor, streams results) |
| `SystemJunkViewModel.swift` | how a screen holds state and drives the scan |
| `SystemJunkView.swift` | how the UI renders that state |
| `SystemJunkDeleter.swift` | how removal actually happens |

Start with `SystemJunkViewModel.live(...)` and read it closely. That one
function explains the whole architecture (see §4).

### Step 2 — the plumbing underneath

| file | what it is |
| --- | --- |
| `FileScanner.swift` | the shared directory walker every scanner uses. Also home to `PathExclusionMatcher`, which runs once per file — read the comments before touching it. |
| `NavigationSection.swift` | the app's top-level structure, one case per sidebar item |
| `ContentView.swift` | maps the selected section to its screen |
| `VaderCleanerApp.swift` | app entry point, window setup, app-scope state |

### Step 3 — the parts with their own rules

Only when you need them:

- **`CareScanEngine.swift` + `CarePlan.swift`** — Smart Scan. It runs scan
  units concurrently and produces a `CarePlan` of `CareFinding`s carrying
  safety tiers. It's the most intricate feature; don't start here.
- **`Shared/HelperProtocol.swift`** — the XPC interface to the privileged
  helper. Compiled into *both* targets, so changing it means updating the
  helper, the app, and every test spy together.
- **`ManagerItemTable.swift`** — an `NSTableView` bridged into SwiftUI. It
  exists because SwiftUI lists jank at tens of thousands of rows and a junk
  category can hold far more.

---

## 4. The one pattern that explains everything

**Collaborators are injected as closures.** Every view model takes its
scanners, removers, and system probes as closure properties, plus a
`live()` static factory that wires the real ones. Nineteen view models do this.

```swift
// Production wiring — the only place that knows about the real scanner.
static func live(exclusions: ExclusionsStore) -> SystemJunkViewModel {
    SystemJunkViewModel(
        scanner: { onProgress in
            let excluded = (exclusions?.exclusions ?? []).map { URL(fileURLWithPath: $0) }
            return try await SystemJunkScanner.live().scan(excluding: excluded, onProgress: onProgress)
        },
        // …
    )
}
```

Once you see this, the test suite makes sense:

```swift
// A test drives the real state machine against a fake, with no mock framework.
let vm = SystemJunkViewModel(scanner: { _ in ScanResult(files: [/* … */]) })
```

**Why it matters to you:** there is no mocking framework in this repo and you
should not add one. If something is hard to test, the answer is almost always
"inject that dependency as a closure", not "reach for a mock".

Two supporting rules:

- Tests record through `TestBox` (`VaderCleanerTests/Helpers/TestBox.swift`),
  because a `@Sendable` closure cannot capture a local `var`.
- `XCTestCase` subclasses that touch main-actor state are `@MainActor` and
  override the **async** lifecycle hooks (`setUp() async throws`). The sync
  `setUp()` is `nonisolated`, so overriding it from a `@MainActor` class
  produces an isolation warning on every line.

### The layers

```
View  (SwiftUI)                     ← renders state, sends user intent
  ↓
ViewModel  (@Observable, @MainActor) ← owns state, holds injected closures
  ↓
Scanner / Remover  (Sendable value)  ← does the work off the main actor
  ↓
FileScanner / XPC helper             ← touches the filesystem
```

Stores (`*Store.swift`) sit beside view models and own persisted preferences
and scan scope. They're `@Observable` and main-actor isolated.

---

## 5. Traps that will cost you an hour

**Three section names don't match what the UI shows.** If you saw a screen
called "Cleanup" and grep for it, you'll find nothing useful:

| code | UI label | files |
| --- | --- | --- |
| `.systemJunk` | Cleanup | `SystemJunk*` |
| `.largeOldFiles` | My Clutter | `MyClutter*` |
| `.malwareRemoval` | Protection | `Protection*`, `Malware*` |

**Error text is user data.** `error.localizedDescription` is always
`.private` in logs, because Foundation embeds the offending filename verbatim:
a failed delete reads `"Tax Return 2025.pdf" couldn't be removed…`. Masking
the path you passed in does nothing if the error beside it is `.public`. Only
compile-time-safe context — counts, exit codes, task kinds — is `.public`.
Never `print()`; always `os.Logger` with an explicit privacy annotation.

**Deleting user files goes through `UserFileRecycler`.** Never hand-roll an
`NSWorkspace.recycle` wrapper. Four copies had drifted apart on empty-input
handling before it existed.

**`ENABLE_USER_SCRIPT_SANDBOXING` must stay `NO`.** Xcode's "update to
recommended settings" turns it on and breaks the ClamAV staging build phase.
It's pinned in `project.yml`; decline that suggestion.

**Swift 6, zero warnings, and that includes the test targets.** A clean
incremental build is not evidence, because only recompiled files re-emit
warnings. To check honestly:

```bash
xcodebuild clean build-for-testing -project VaderCleaner.xcodeproj -scheme VaderCleaner -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="skip-dev-seal"
```

**Anything that runs per file is a hot path.** A scan visits over a million
items, so a few microseconds per file is seconds of wall clock. Before
"simplifying" something in `FileScanner` or `DiskScanner`, read its comments —
several of them exist to explain why the obvious version was too slow.

**Lists whose length the user's machine decides must be lazy.** Cookie hosts,
malware threats, and background items are uncapped. An eagerly-built stack of
3,000 rows costs half a second of layout on every body pass.

---

## 6. Adding a feature: the recipe

1. Add the file to the right directory, then `xcodegen generate`.
2. Start the file with the two-line comment: filename, then what it does.
   Every source file in the app, `Shared/`, and the helper does this without
   exception; keep the streak.
3. **Write the test first.** This repo practises TDD, and the suite is
   hermetic — real state machines against fake closures.
4. Inject collaborators as closures; add a `live()` factory for production.
5. Log through `os.Logger` with privacy annotations. Paths and error text are
   `.private`.
6. Before opening a PR:
   ```bash
   swiftlint lint          # 0 errors expected; warnings are advisory
   swiftformat . --lint    # should report no files needing formatting
   ```

### On the lint warnings

`swiftlint` reports ~99 warnings and **0 errors**. That's expected and
triaged — most are size and complexity warnings on genuinely large files, and
the force unwraps cluster in `#Preview` scaffolding and a geometry solver where
the invariant is local. **Check the category before "fixing" one.** Several
past lint suggestions in this repo were unsound and would not have compiled.

---

## 7. Where things live

```
VaderCleaner/          the app — views, view models, scanners, stores
Shared/                types compiled into BOTH the app and the helper
VaderCleanerHelper/    the privileged XPC daemon (runs as root)
VaderCleanerTests/     unit tests (~2,270 of them)
VaderCleanerUITests/   XCUITests — run these from Xcode
Scripts/               build-phase scripts (ClamAV staging, dev signing)
docs/                  design notes; docs/history/ is a historical record
project.yml            the source of truth for the Xcode project
```

**`docs/history/` has diverged from current behaviour.** It records how the
app was built, not how it works now. Read `docs/history/README.md` before
trusting anything in there.

---

## 8. Glossary

Terms that appear everywhere and are not obvious from the names:

| term | meaning |
| --- | --- |
| **Care plan / care finding** | Smart Scan's output. A `CarePlan` is a set of `CareFinding`s, each carrying a safety tier that decides whether Run may act on it automatically. |
| **Pre-approved vs opt-in** | A finding's `actionability`. Pre-approved findings are included the moment results land; opt-in ones are included only once the user checks something. Informational ones are never actionable. |
| **Manager** | The full-screen review UI for a section (`*ManagerView.swift`) — the list where the user picks exactly what to remove. |
| **Facet** | A filter in a manager's sidebar (by vendor, by store, by category). |
| **Scan root** | A directory to walk, paired with the `ScanCategory` to tag everything under it. |
| **Exclusion** | A path the user has told the app to ignore. Matched at path-component boundaries so excluding `/tmp/foo` doesn't also exclude `/tmp/foobar`. |
| **FDA** | Full Disk Access, the macOS permission the app needs to see most of what it scans. |
| **The helper** | `VaderCleanerHelper`, the privileged daemon. Anything needing root goes over XPC to it. |
| **Space Lens** | The disk visualisation — a treemap of where the bytes are. |

---

## 9. Your first week

- **Day 1** — get it building, get the unit suite green, run the app.
- **Day 2** — read the Cleanup slice in §3 end to end. Then read
  `SystemJunkViewModelTests.swift` and watch how the fakes drive it.
- **Day 3** — pick a small bug. Write the failing test first.
- **Later** — Smart Scan (`CareScanEngine`) and the XPC helper. Both have
  rules of their own; neither is a good first task.

When something looks wrong, check whether a comment already explains it. A
large share of the comments in this codebase exist specifically to stop the
next person from "fixing" a deliberate decision — an unusual symlink policy, a
throttled yield, a lock that looks unnecessary. If a comment turns out to be
actively false, fix the comment in the same PR.
