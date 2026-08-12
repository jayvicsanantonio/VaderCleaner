# Shipping VaderCleaner to your first testers

How to get a build of VaderCleaner onto a friend's Mac so it opens with a single
click and no scary warnings — without the App Store, and without TestFlight.

This guide assumes you've built Mac apps in Xcode but have never shipped one to
someone else. It explains *why* each step exists, not just what to type.

---

## Table of contents

- [The short version](#the-short-version)
- [Why not the App Store or TestFlight](#why-not-the-app-store-or-testflight)
- [The mental model: four gates](#the-mental-model-four-gates)
- [Where this project stands today](#where-this-project-stands-today)
- [What you need before you start](#what-you-need-before-you-start)
- [The steps](#the-steps)
  - [Step 1 — Get a Developer ID certificate](#step-1--get-a-developer-id-certificate)
  - [Step 2 — Save your notary credentials](#step-2--save-your-notary-credentials)
  - [Step 3 — Fix the Release build settings](#step-3--fix-the-release-build-settings)
  - [Step 4 — Archive and export](#step-4--archive-and-export)
  - [Step 5 — Verify before you notarize](#step-5--verify-before-you-notarize)
  - [Step 6 — Package it as a DMG](#step-6--package-it-as-a-dmg)
  - [Step 7 — Notarize and staple](#step-7--notarize-and-staple)
  - [Step 8 — Verify like a tester](#step-8--verify-like-a-tester)
  - [Step 9 — Hand it over](#step-9--hand-it-over)
- [What your testers will experience](#what-your-testers-will-experience)
- [Things specific to this app](#things-specific-to-this-app)
- [Troubleshooting](#troubleshooting)
- [Glossary](#glossary)

---

## The short version

Nine steps, and only steps 1–3 are one-time setup:

1. Join the Apple Developer Program, create a **Developer ID Application**
   certificate
2. Save notary credentials to your keychain
3. Turn on hardened runtime and Developer ID signing for **Release** builds
4. `xcodebuild archive` → `xcodebuild -exportArchive`
5. Verify the signature locally (free, instant — do this before wasting a
   notary round-trip)
6. Wrap the `.app` in a `.dmg`
7. `notarytool submit` → `stapler staple`
8. Verify the way Gatekeeper will
9. Send the DMG

After the first time, steps 4–9 take about five minutes and are worth putting in
a script.

---

## Why not the App Store or TestFlight

**TestFlight** is Apple's beta-testing service: you upload a build, invite people
by email or link, and they install through the TestFlight app. It's genuinely
nice — it gives you crash reports and in-app feedback for free.

But TestFlight distributes through App Store Connect, which means a build has to
be **App-Store-eligible even though it never appears in the store**. VaderCleaner
isn't, for four independent reasons:

| Blocker | Where it lives |
| --- | --- |
| The app is unsandboxed | App Store requires `com.apple.security.app-sandbox`. A sandboxed cleaner can't read another app's caches — the sandbox is the exact thing it exists to work around. |
| A privileged root daemon | `Contents/Library/LaunchDaemons/com.personal.VaderCleaner.helper.plist`, registered via `SMAppService`. Not permitted for App Store apps. |
| Bundled ClamAV | `Scripts/clamav.entitlements` disables library validation, and `freshclam` downloads definition data at runtime. |
| Uninstalling other apps | Impossible from inside a container. |

None of these are packaging problems you can configure away. Getting on
TestFlight would mean deleting most of the app.

**Developer ID + notarization** is the standard alternative, and it's what
basically every serious Mac utility outside the store uses. That's what the rest
of this guide covers.

---

## The mental model: four gates

Most of the confusion around Mac distribution comes from treating this as one
thing. It's four separate systems that happen to line up. Understanding them
separately makes every error message obvious.

### Gate 1 — Code signing: "who made this?"

A cryptographic signature over every byte in your app bundle. It proves two
things: **who** built it (your certificate identity) and that **nothing has been
modified** since.

The critical part junior engineers usually miss: **there are different kinds of
certificate, and they are not interchangeable.**

- **Apple Development** — for running on your own machines during development.
  This is what you have now.
- **Apple Distribution** — for uploading to App Store Connect.
- **Developer ID Application** — for distributing outside the store. **This is
  the one you need.**

Signing with the wrong type isn't a warning; it's a hard rejection. A perfectly
valid Apple Development signature gets refused on someone else's Mac.

### Gate 2 — Hardened runtime: "what is it allowed to do?"

An opt-in security mode that blocks a set of exploit techniques — injecting code
into your process, loading unsigned libraries, attaching a debugger. You turn it
on with a build setting, and then poke specific holes with entitlements where
your app legitimately needs them.

**Notarization refuses anything without it.** That's the only reason you care.

### Gate 3 — Notarization: "has Apple scanned it?"

You upload your signed app to Apple. An automated service scans it for malware
and checks it's correctly signed, then issues a **ticket** — a small
cryptographic receipt saying "Apple has seen this exact build."

Two things it is *not*:

- **It is not App Review.** No human looks at it. There are no guidelines to
  satisfy. It usually finishes in under five minutes.
- **It is not an endorsement.** It means "scanned, and we know who signed it,"
  not "we think this is good software."

**Stapling** attaches that ticket to your DMG so it works offline. Without
stapling, every tester's Mac has to phone Apple on first launch — which fails on
bad wifi and on planes.

### Gate 4 — Gatekeeper: "should this run here?"

The check that happens on your *tester's* Mac at first launch.

When a file arrives by download, AirDrop, or Messages, the receiving app tags it
with an extended attribute called `com.apple.quarantine`. Gatekeeper only does
its full inspection on files carrying that tag — which is exactly why an app you
build locally just runs, while the identical app your friend downloads gets
interrogated.

It asks: is the signature valid and unmodified? Is there a notarization ticket?
Is this on Apple's known-bad list?

- **All three pass** → one dialog: *"VaderCleaner is an app downloaded from the
  Internet. Are you sure you want to open it?"* One click, never asked again.
- **Any fail** → blocked. Since macOS 15, the old Control-click → Open trick no
  longer works. Your tester has to open System Settings → Privacy & Security,
  scroll to a warning about the blocked app, click **Open Anyway**, and
  authenticate. For an app that also wants Full Disk Access and installs a root
  daemon, some people will reasonably decide not to.

Avoiding that four-step ritual is the entire point of this guide.

---

## Where this project stands today

Measured against the current Debug build, so you can see what changes:

```
spctl -a -t exec -vvv VaderCleaner.app
→ rejected
  origin=Apple Development: sanantonio.jayvic@gmail.com
```

| Check | App | Helper | clamscan |
| --- | --- | --- | --- |
| Signature valid & unmodified | ✅ | ✅ | ✅ |
| Developer ID certificate | ❌ (Apple Development) | ❌ | ❌ |
| Hardened runtime | ❌ `flags=0x0(none)` | ❌ | ✅ `flags=0x10000(runtime)` |
| Secure timestamp | ❌ | ❌ | ✅ |
| Notarization ticket | ❌ | — | — |

Two useful things to notice:

**The signature itself is sound.** `codesign --verify --deep --strict` reports
*valid on disk* and *satisfies its Designated Requirement*. The nested signing —
helper, dylibs, ClamAV — is already correct. Nothing is broken; you're only
missing the distribution certificate and the ticket.

**ClamAV is already signed the right way.** `Scripts/stage-clamav.sh` reads
`EXPANDED_CODE_SIGN_IDENTITY` from the build and, when a real identity is
present, signs with `--options runtime --timestamp`. It will pick up your
Developer ID certificate automatically, with no changes. The app and helper are
the ones that need fixing.

The app also carries `com.apple.security.get-task-allow` — Xcode's debugger
entitlement, which the notary service rejects. This one disappears on its own in
a Release build; you don't need to do anything about it.

---

## What you need before you start

- **An Apple Developer Program membership** — $99/year. There is no free path
  here. Notarization requires a Developer ID certificate, and Developer ID
  certificates require paid membership.
- **Xcode command line tools** — you have these.
- **An app-specific password** for your Apple ID, generated at
  [account.apple.com](https://account.apple.com) → Sign-In and Security →
  App-Specific Passwords. Your regular Apple ID password will not work for
  notarization.
- **About 30 minutes** for the first run. Most of it is waiting on Apple's
  website.

> A note on the $99: it's per year, and it covers unlimited apps and unlimited
> testers. If you're on the fence, this is the cost of your testers not having
> to click through a security warning — and for a disk cleaner that asks for
> Full Disk Access, that trust gap is the difference between people trying it
> and quietly not bothering.

---

## The steps

### Step 1 — Get a Developer ID certificate

1. Enroll at [developer.apple.com/programs](https://developer.apple.com/programs).
   Approval can take anywhere from an hour to a couple of days.
2. Once approved, the easiest route is Xcode: **Settings → Accounts → your Apple
   ID → Manage Certificates → + → Developer ID Application**.
3. Confirm it landed:

```bash
security find-identity -v -p codesigning
```

You want a line reading `Developer ID Application: Your Name (TEAMID)`. You'll
have your existing `Apple Development` line too — that's fine, they coexist.

> **A trap worth knowing.** The 10-character code in parentheses means different
> things on different certificate types. On a **Developer ID Application**
> certificate it *is* your Team ID. On an **Apple Development** certificate it's
> your personal user ID, and the Team ID is a different string entirely. Get
> your real Team ID from the Developer ID line, or from the membership page at
> developer.apple.com. Using the wrong one produces confusing signing failures.

### Step 2 — Save your notary credentials

You don't want to type an app-specific password into every notarization command.
Store it once in your keychain under a nickname:

```bash
xcrun notarytool store-credentials VaderNotary --apple-id "sanantonio.jayvic@gmail.com" --team-id "YOUR_TEAM_ID" --password "your-app-specific-password"
```

`VaderNotary` is just a label you pick. From now on every notarization command
takes `--keychain-profile VaderNotary` and no secrets.

**Do not commit this password anywhere.** The keychain is the right place for it.

### Step 3 — Fix the Release build settings

Two changes, both in `project.yml`, because this project generates its Xcode
project with XcodeGen. **Never edit `VaderCleaner.xcodeproj` by hand** — it gets
regenerated and your changes vanish.

**3a. Hardened runtime, Release only.** Today `project.yml` pins
`ENABLE_HARDENED_RUNTIME: NO` for every configuration. Debug needs it off (it
interferes with the debugger and with ad-hoc local signing); Release needs it on.
Split it:

```yaml
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "26.0"
    ENABLE_USER_SCRIPT_SANDBOXING: NO
  configs:
    Debug:
      ENABLE_HARDENED_RUNTIME: NO
    Release:
      ENABLE_HARDENED_RUNTIME: YES
```

**3b. Developer ID signing for Release.** The project maps both configurations to
`Signing.xcconfig`, which deliberately signs with no identity. Follow the same
pattern the repo already uses for local overrides: make a
`Distribution.xcconfig`, keep it out of git, and point Release at it.

Create `Distribution.xcconfig`:

```
// Distribution.xcconfig
// Release signing for notarized Developer ID builds. Gitignored — it carries a
// personal Team ID.

CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Developer ID Application
CODE_SIGNING_REQUIRED = YES
CODE_SIGNING_ALLOWED = YES
DEVELOPMENT_TEAM = YOUR_TEAM_ID

// Secure timestamps are required for notarization. Xcode normally adds these
// when exporting for distribution; setting it explicitly means a plain
// `xcodebuild -configuration Release` produces a notarizable binary too.
OTHER_CODE_SIGN_FLAGS = --timestamp
```

Add it to `.gitignore` next to `Signing.local.xcconfig`, then point Release at it
in `project.yml`:

```yaml
configFiles:
  Debug: Signing.xcconfig
  Release: Distribution.xcconfig
```

Regenerate:

```bash
xcodegen generate
```

You don't need to touch `Scripts/sign-dev.sh`. It checks for a real signing
identity and no-ops when it finds one, so it will step aside automatically for
Release builds. That's by design.

### Step 4 — Archive and export

An **archive** is a build plus its debug symbols, packaged for distribution.
**Exporting** an archive re-signs its contents for a specific distribution
channel and gives you the final `.app`.

```bash
xcodebuild -project VaderCleaner.xcodeproj -scheme VaderCleaner -configuration Release -archivePath build/VaderCleaner.xcarchive archive
```

Then write `build/exportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>YOUR_TEAM_ID</string>
  <key>signingStyle</key>
  <string>manual</string>
</dict>
</plist>
```

`method` is the important key — it tells Xcode which certificate class to sign
with. `developer-id` means "outside the App Store."

```bash
xcodebuild -exportArchive -archivePath build/VaderCleaner.xcarchive -exportOptionsPlist build/exportOptions.plist -exportPath build/export
```

You now have `build/export/VaderCleaner.app`.

### Step 5 — Verify before you notarize

Notarization round-trips take minutes. Local verification takes seconds and
catches most problems. Always do this first.

```bash
codesign -dvv build/export/VaderCleaner.app
```

Read three lines of the output:

- `Authority=Developer ID Application: ...` — right certificate class
- `flags=0x10000(runtime)` — hardened runtime is on
- `Timestamp=...` — a secure timestamp exists (this is a *different* line from
  `Signed Time`, which doesn't count)

Then check the whole bundle, including everything nested inside it:

```bash
codesign --verify --deep --strict --verbose=2 build/export/VaderCleaner.app
```

You want `valid on disk` and `satisfies its Designated Requirement`.

Check the helper separately, because it has a requirement nothing else does:

```bash
codesign -dvv build/export/VaderCleaner.app/Contents/MacOS/VaderCleanerHelper
```

It **must** report `Identifier=com.personal.VaderCleaner.helper`. A command-line
tool signs under its executable name by default, and if it comes out as
`VaderCleanerHelper` the app's XPC connection will be rejected at runtime and
every privileged feature dies. `project.yml` already handles this via
`CREATE_INFOPLIST_SECTION_IN_BINARY`, but verify it — this failure is silent
until a user tries to run an Optimization action.

Finally, run Apple's own preflight, which checks the same things the notary
service will:

```bash
syspolicy_check notary-submission build/export/VaderCleaner.app
```

### Step 6 — Package it as a DMG

You *can* send a zip, but a DMG is better for this app: it gives you a window
with an `/Applications` shortcut, which nudges people to actually install it
rather than run it from Downloads.

That matters more than it sounds. macOS has a feature called **App
Translocation**: a quarantined app launched from `~/Downloads` is silently run
from a randomized read-only location. Anything that resolves paths relative to
its own bundle — such as, say, bundled ClamAV binaries — can misbehave until the
app is moved to `/Applications`. The `/Applications` alias in the DMG window is
how you avoid a whole class of confusing bug reports.

```bash
mkdir -p build/dmg && cp -R build/export/VaderCleaner.app build/dmg/ && ln -s /Applications build/dmg/Applications
```

```bash
hdiutil create -volname VaderCleaner -srcfolder build/dmg -ov -format UDZO build/VaderCleaner.dmg
```

Sign the DMG itself, so the container is tamper-evident too:

```bash
codesign --force --sign "Developer ID Application" --timestamp build/VaderCleaner.dmg
```

### Step 7 — Notarize and staple

```bash
xcrun notarytool submit build/VaderCleaner.dmg --keychain-profile VaderNotary --wait
```

`--wait` blocks until Apple finishes, usually two to fifteen minutes. You want
`status: Accepted`.

If it says `Invalid`, get the details — the summary alone won't tell you what
went wrong:

```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile VaderNotary
```

That prints a JSON list of every offending binary and why. See
[Troubleshooting](#troubleshooting) below.

Once accepted, attach the ticket to the DMG:

```bash
xcrun stapler staple build/VaderCleaner.dmg
```

### Step 8 — Verify like a tester

Notarizing isn't proof that Gatekeeper is happy. Check directly:

```bash
spctl -a -t open --context context:primary-signature -vvv build/VaderCleaner.dmg
```

You want `accepted` and `source=Notarized Developer ID`.

For the real test, mount the DMG, copy the app out, and simulate the quarantine
tag a download would apply:

```bash
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;$(uuidgen)" /tmp/VaderCleaner.app
```

```bash
spctl -a -t exec -vvv /tmp/VaderCleaner.app
```

`accepted` here means a tester gets the single friendly dialog and nothing more.

### Step 9 — Hand it over

Anywhere that transfers a file works: AirDrop, Google Drive, Dropbox, or a
**GitHub Release** on the repo. GitHub Releases are the nicest option — testers
get a stable download URL, you get a natural place to write release notes, and
old versions stay available when you need someone to confirm a regression.

---

## What your testers will experience

Send them this list. Every item is normal, and none of it is a bug.

1. **Download and drag to Applications.** Not Downloads — see App Translocation
   above.
2. **First launch shows one dialog** — *"VaderCleaner is an app downloaded from
   the Internet…"*. Click Open. It never appears again.
3. **Full Disk Access must be granted by hand.** System Settings → Privacy &
   Security → Full Disk Access → add VaderCleaner. macOS does not allow an app
   to request this programmatically. Without it, a disk cleaner can't see most of
   what it's meant to clean. Tell people this up front, and tell them why —
   asking for Full Disk Access without explanation is exactly what malware does,
   and skepticism here is healthy.
4. **The privileged helper needs approval.** The first time they use a feature
   that needs root, macOS shows a background-item notification. They approve it
   under System Settings → General → Login Items & Extensions. This is a
   *separate* prompt from Gatekeeper and appears later.
5. **They need macOS 26.** The deployment target is 26.0. Anyone on 15 or
   earlier can't run it at all — check before you send.

---

## Things specific to this app

**Bump the version on every build you send out.** `project.yml` currently pins
`CFBundleShortVersionString: "1.0"` and `CFBundleVersion: "1"`. If you don't
change these, you won't be able to tell which build a bug report came from, and
neither will your tester. Bump `CFBundleVersion` for every single build you hand
to anyone.

**You get no crash reports.** This is the real thing you give up versus
TestFlight. Outside the store, nothing is collected automatically. Give people a
concrete way to reach you — a GitHub issue link is the low-effort option. Ask
them to include the version string from the app.

**Updates are manual.** Every new version means sending a new DMG and asking
people to re-install. If this app grows past a handful of testers, the standard
answer for Developer ID apps is [Sparkle](https://sparkle-project.org) — an
update framework that gives you the "check for updates" behavior users expect.
Not worth setting up for five friends; very much worth it for fifty.

**One known structural warning.** Apple's preflight reports:

```
Incorrect Bundle Structure — Severity: Warning
  Contents/Resources/clamav/bin/clamscan  — Resources directory contains Mach-o binaries
  Contents/Resources/clamav/bin/freshclam — same
```

The convention is that executables live in `Contents/MacOS` or
`Contents/Helpers`, not `Contents/Resources`. This is warning-level and does not
block notarization — but it's the kind of thing Apple tightens over time.
Changing it means touching `Scripts/stage-clamav.sh` and every runtime path that
resolves the ClamAV prefix, so it's a deliberate piece of work, not a quick fix.
Worth tracking as an issue rather than doing under deadline.

**The app is 19 MB of ClamAV before anything else.** Expect a DMG in the tens of
megabytes. Fine for direct download; just don't try to email it.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `spctl` says `rejected`, `origin=Apple Development` | Signed with a development certificate | Use Developer ID Application (Step 3) |
| Notary: *The executable does not have the hardened runtime enabled* | `ENABLE_HARDENED_RUNTIME` off | Step 3a. Check the named binary — a nested one is easy to miss |
| Notary: *The signature does not include a secure timestamp* | Signed without `--timestamp` | Step 3b's `OTHER_CODE_SIGN_FLAGS` |
| Notary: *The executable requests the com.apple.security.get-task-allow entitlement* | Debug build submitted | Archive with `-configuration Release` |
| Notary: *The binary is not signed with a valid Developer ID certificate* | A nested binary was missed | `codesign --verify --deep --strict` finds it; check dylibs and ClamAV binaries |
| Accepted, but testers still get blocked | Ticket never stapled | `xcrun stapler staple` (Step 7) |
| Helper never registers; Optimization actions fail | Helper signed under the wrong identifier | Verify `Identifier=com.personal.VaderCleaner.helper` (Step 5) |
| Works from `/Applications`, breaks from `~/Downloads` | App Translocation | Tell testers to drag to Applications |
| `notarytool` rejects your password | Regular Apple ID password used | Generate an app-specific password (Step 2) |

When notarization fails, always read `notarytool log`. The one-line status never
tells you which binary was at fault; the log always does.

---

## Glossary

**Ad-hoc signature** — a signature with no certificate behind it (`codesign -s -`).
Enough to run locally, useless for distribution, and it changes on every build,
which is why `SMAppService` refuses to register a helper signed this way.

**App Translocation** — macOS running a quarantined app from a randomized
read-only location instead of where it sits on disk. Goes away once the app is
moved to `/Applications`.

**Designated Requirement (DR)** — the rule embedded in a signature describing
what a valid future version of this code looks like. It's how macOS knows an
update is "the same app" and how the helper verifies it's talking to the real
VaderCleaner over XPC.

**Entitlement** — a permission flag baked into a signature. Some open holes in
the hardened runtime; others grant access to protected resources.

**Gatekeeper** — the first-launch check on the tester's Mac. Signature +
notarization ticket + not-known-malware.

**Hardened runtime** — opt-in exploit mitigations. Required for notarization.

**Notarization** — Apple's automated malware scan of your build, producing a
ticket. Not App Review; no human is involved.

**Quarantine** — the `com.apple.quarantine` extended attribute that download
paths attach to files. It's what triggers a Gatekeeper check at all.

**Stapling** — attaching the notarization ticket to your DMG so verification
works offline.

**XProtect** — macOS's built-in malware scanner. Separate from Gatekeeper, though
they're often confused.
