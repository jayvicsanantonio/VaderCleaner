# Build history

These are the documents the app was originally built from. They are kept as a
record of the original design and sequencing — **not** as a description of how
VaderCleaner works today. For current behaviour, read the code, `README.md`, or
`CLAUDE.md`.

| Document | What it was |
|---|---|
| `spec.md` | The original feature specification. |
| `plan.md` | The 27-prompt implementation plan derived from the spec. |
| `todo.md` | The build checklist for that plan — every item is complete. |

They were moved here rather than deleted because they explain *why* several
architectural decisions were made, which the code alone does not record.

## Where they have since diverged

Treat any statement in these files as historical unless the code confirms it.
Known divergences:

- **ClamAV is bundled, not sourced from Homebrew.** `plan.md` decided against
  bundling and had the app guide the user to a Homebrew install. The app now
  stages its own ClamAV into the bundle (the `Stage bundled ClamAV` build phase
  in `project.yml`, via `Scripts/stage-clamav.sh`); `ClamAVDetector` checks the
  bundled copy first and only falls back to Homebrew prefixes.
- **The section set and navigation have moved on.** The scan-centric redesign in
  `todo.md`'s Phase 6 replaced the per-section idle states these documents
  describe, and Smart Scan has since been rebuilt around `CareScanEngine` and
  its care-plan model.
- **The minimum deployment target is macOS 26**, and the app builds in the
  Swift 6 language mode. Neither is mentioned in the originals.
