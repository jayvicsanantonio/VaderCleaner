# Optimization — User Guide

The **Optimization** section keeps your Mac running smoothly by handling routine
upkeep that macOS doesn't always do on its own. Think of it as a tune‑up for your
computer: a handful of safe, well‑understood maintenance jobs you can run with a
single click.

This guide explains, in plain language, what the section shows you, what each task
actually does, and the trade‑offs of running it — so you can decide what's worth
doing and when.

---

## Table of contents

- [How the section is laid out](#how-the-section-is-laid-out)
- [The recommendation cards](#the-recommendation-cards)
- [The tasks, explained](#the-tasks-explained)
  - [Free Up RAM](#free-up-ram)
  - [Run Maintenance Scripts](#run-maintenance-scripts)
  - [Flush DNS Cache](#flush-dns-cache)
  - [Reindex Spotlight](#reindex-spotlight)
  - [Thin Time Machine Snapshots](#thin-time-machine-snapshots)
  - [Speed Up Mail](#speed-up-mail)
- [Background Items](#background-items)
- [Frequently asked questions](#frequently-asked-questions)
- [Quick reference table](#quick-reference-table)

---

## How the section is laid out

When you open **Optimization**, you'll see two views:

1. **The dashboard** (the first thing you see). This is a set of *recommendation
   cards*. The app looks at the current state of your Mac and surfaces the things
   most worth doing right now — for example, freeing up memory, or thinning old
   backup snapshots that are taking up space. Each card has a button to act on it.

2. **View All Tasks** (a button on the dashboard). This opens the full *catalog*,
   organized like a control panel with a list on the left:
   - **Maintenance Tasks** — every task with a checkbox and a colorful icon. Tick
     the ones you want, and the bar at the bottom shows how many you've selected
     and a **Run** button that runs them all together. Each row also has an **info
     (ⓘ)** button that explains, in a sentence, what the task does.
   - **Login Items** — apps set to launch when you log in.
   - **Background Items** — helper programs that start automatically with your Mac.

   Use the catalog when you want to choose tasks yourself rather than follow a
   recommendation.

You can move back and forth freely. Nothing runs until you click a button.

> **A note on permissions.** Most of these tasks change system‑level settings, so
> macOS requires administrator rights. VaderCleaner performs them through a small,
> signed background helper that has permission to do this safely. You may be asked
> to approve the helper the first time. The one exception is **Speed Up Mail**,
> which works at the user level and needs the Mail app to be closed.

---

## The recommendation cards

The dashboard chooses what to show based on your Mac's current condition:

| Card | When it appears | What its button does |
| --- | --- | --- |
| **Free Up Your RAM** | Always — it's the main, permanent card | Frees inactive memory |
| **N Maintenance Tasks Recommended** | When routine tasks haven't run in a while (over a week) | Runs all the due upkeep tasks in one go |
| **N Background Items Found** | When apps/helpers start automatically with your Mac | Opens the list so you can review them |
| **Thin Time Machine Snapshots** | When local backup snapshots are using disk space | Reclaims that space |

The number on a card (like "3 Maintenance Tasks Recommended") matches exactly what
its button will do — if it says three tasks, clicking **Run Tasks** runs those
three.

If your Mac is in good shape, the dashboard may only show the RAM card. That's
normal — it means there's nothing else worth doing right now. You can still open
**View All Tasks** to run anything manually.

---

## The tasks, explained

Each task below includes a plain‑English description, when it helps, and the
pros and cons so you know what you're trading off.

---

### Free Up RAM

**What it is.** RAM (memory) is your Mac's short‑term workspace — where apps keep
the things they're actively using. Over time, closed apps can leave behind
"inactive" memory that isn't doing anything useful. This task asks macOS to
release that inactive memory back to the pool.

**When it helps.** If your Mac feels sluggish after a long session with many apps
open and closed, or you're about to start something memory‑hungry (video editing,
a virtual machine, lots of browser tabs).

**Pros**
- Quick and safe; nothing is deleted.
- Can give active apps a bit more breathing room.

**Cons**
- macOS already manages memory well on its own. The benefit is often small and
  temporary — memory fills back up as you keep working.
- Right after running it, your Mac may briefly feel *slower* as apps reload things
  they need from disk.

**Bottom line.** Harmless and occasionally helpful, but not something you need to
do regularly. macOS usually handles this for you.

---

### Run Maintenance Scripts

**What it is.** macOS ships with built‑in housekeeping routines (called the
*daily*, *weekly*, and *monthly* periodic scripts). They tidy up temporary files,
rotate and compress old log files, and refresh some system databases. They're
scheduled to run automatically — but only if your Mac is awake at the right time.
Many Macs are asleep overnight, so these can fall behind. This task runs them on
demand.

**When it helps.** If your Mac is frequently asleep or shut down overnight, the
scripts may rarely run on their own. Running them manually catches up the backlog.

**Pros**
- Keeps logs from piling up and clears out stale temporary files.
- Standard, Apple‑provided maintenance — very safe.

**Cons**
- The effect is mostly invisible; you won't see a dramatic speed‑up.
- Can take a little while and use some CPU while it runs.

**Availability.** This task only appears on Macs that still include the system
`periodic` tool. Apple has removed it from recent macOS, where the system handles
this upkeep itself — on those Macs the task simply won't show.

**Bottom line.** Good occasional housekeeping, especially if your Mac doesn't stay
awake overnight. Low risk.

---

### Flush DNS Cache

**What it is.** When you visit a website, your Mac remembers ("caches") the address
lookup so it doesn't have to ask again every time. Occasionally that cached
information goes stale — for example, after a website moves, or your network
changes. This task clears the cache so your Mac fetches fresh address information.

**When it helps.** A site won't load, loads the wrong/old version, or you've just
changed network settings (new router, VPN, switched DNS providers) and pages behave
oddly.

**Pros**
- Often fixes "this site works on my phone but not my Mac" type problems.
- Instant and safe.

**Cons**
- The next few lookups are a touch slower while the cache rebuilds (you won't
  really notice).
- Does nothing if your problem isn't DNS‑related.

**Bottom line.** A great first thing to try for stubborn website or connection
issues. No downside worth worrying about.

---

### Reindex Spotlight

**What it is.** Spotlight is your Mac's built‑in search (the magnifying glass).
It keeps an *index* — a catalog of your files — so searches are instant. If search
starts missing files or returning wrong results, the index may be corrupted. This
task erases and rebuilds it from scratch.

**When it helps.** Spotlight search is incomplete, slow, or returns stale results.

**Pros**
- Restores accurate, fast search once rebuilding finishes.
- Fixes a class of problems nothing else can.

**Cons**
- **Rebuilding takes time** — anywhere from minutes to a couple of hours depending
  on how much data you have.
- **While it rebuilds, search will be slow or incomplete**, and your Mac may run
  warmer and use more CPU. Best to start it when you don't urgently need search.

**Bottom line.** Powerful fix, but disruptive while it works. Only run it when
search is actually misbehaving, and ideally when you can leave the Mac to finish.

---

### Thin Time Machine Snapshots

**What it is.** Time Machine (Apple's backup system) keeps temporary *local
snapshots* on your Mac's own disk between backups to your external/network drive.
These are handy, but they can quietly eat up disk space. This task asks macOS to
trim them down.

**When it helps.** You're low on disk space and Time Machine is enabled. "Purgeable"
space that you can't seem to free up is often these snapshots.

**Pros**
- Can reclaim a meaningful amount of disk space.
- **Your real backups are not affected** — only the temporary local copies are
  thinned, and macOS only removes what it safely can.

**Cons**
- If you delete a file and then thin snapshots, the short‑term "undo" that local
  snapshots provide may no longer be available (your proper Time Machine backups
  still are).
- Does nothing if you don't use Time Machine.

**Does this affect my backups or encryption?** No.
- **Your backups are safe.** This only thins the *local* snapshots stored on your
  Mac's internal disk. The full backup history on your external or network Time
  Machine drive is never touched — and macOS only removes what it can safely
  remove. Under the hood, this simply asks macOS to reclaim space
  (`tmutil thinlocalsnapshots`); it does not delete specific backups by hand.
- **Encryption is unchanged.** If FileVault is on, your disk and the snapshots on
  it stay fully encrypted — thinning doesn't decrypt anything. If your Time Machine
  backup drive is encrypted, that's a separate disk this task doesn't touch, so its
  encryption is unaffected too.

**Bottom line.** A safe way to recover disk space if you use Time Machine. Your
backups stay intact and nothing is decrypted — the only cost is losing some very
recent local "undo" points until macOS makes new snapshots.

---

### Speed Up Mail

**What it is.** The Mail app keeps a database (an "envelope index") of all your
messages so it can search and sort quickly. Over time this database can become
bloated or fragmented, making Mail feel slow. This task compacts and rebuilds it.

**When it helps.** Mail is slow to search, sluggish when switching mailboxes, or
generally feels heavy.

**Pros**
- Can noticeably improve Mail's responsiveness and search.
- Doesn't touch your actual emails — only the behind‑the‑scenes index.

**Cons**
- **Mail must be closed** while this runs, or it will fail (the database is locked
  while Mail is open). The app will tell you if that's the case.
- Requires that the app can read your Mail data, which may need **Full Disk Access**
  granted to VaderCleaner in System Settings → Privacy & Security.
- The first time you reopen Mail afterward, it may take a moment to settle.

**Bottom line.** Worth it if Mail feels slow. Just quit Mail first.

---

## Background Items

In **View All Tasks**, below the maintenance tasks, you'll find **Background Items**.
These are programs that start automatically when you log in or boot your Mac:

- **Login Items** — apps set to launch at login.
- **Launch Agents & Daemons** — smaller helper programs (often installed alongside
  other apps) that run quietly in the background.

Too many of these can slow down startup and use resources all day. Here you can:

- **Disable** an item so it stops launching automatically (you can re‑enable it).
- **Remove** a *user* item entirely (this deletes its startup configuration and
  can't be undone from here).

**System daemons are protected.** Items in the "Launch Agents & Daemons (System)"
group belong to macOS itself or to the app that installed them. Removing one can
break your system or that app, so VaderCleaner does not let you remove them here —
the **Remove** button is unavailable for them. If you really need to change a
system daemon, do it through **System Settings** or the app that installed it.

**A word of caution.** Some background items are needed by apps you rely on (for
example, cloud‑storage syncing or keyboard/mouse utilities). Disabling is reversible
and the safer choice; removing is permanent. If you're not sure what something is,
leave it alone or just disable it and see whether anything you use stops working.

---

## Frequently asked questions

**Will any of these delete my files?**
No. None of these tasks touch your documents, photos, or emails. They clear caches,
run housekeeping, trim *temporary* backup snapshots, and rebuild *indexes* — not
your actual data.

**Do I need to run these regularly?**
Not really. Most are "run it when you notice a specific problem" tools rather than
chores. The dashboard will nudge you when something is genuinely worth doing.

**Why does it ask for a password or approval?**
Several tasks change system‑level settings, which macOS protects. VaderCleaner uses
a small signed helper to do this safely; approving it is a one‑time step.

**Can I undo a task?**
There's nothing to undo for most of them — they don't remove anything you'd want
back. Reindex Spotlight and Speed Up Mail simply rebuild their indexes. Removing a
Background Item is the only action that's permanent.

**Is it safe to just click everything?**
Mostly yes, but two tasks are disruptive *while they run*: **Reindex Spotlight**
(search is degraded until it finishes) and **Speed Up Mail** (Mail must be closed).
Run those when it's convenient.

---

## Quick reference table

| Task | What it does | Best for | Main downside | Risk |
| --- | --- | --- | --- | --- |
| **Free Up RAM** | Releases inactive memory | A sluggish Mac after heavy use | Effect is small and temporary | Very low |
| **Run Maintenance Scripts** | Runs Apple's daily/weekly/monthly housekeeping | Macs that sleep overnight | Mostly invisible benefit | Very low |
| **Flush DNS Cache** | Clears stale website address lookups | Sites that won't load right | Brief, unnoticeable slowdown after | Very low |
| **Reindex Spotlight** | Rebuilds the search index | Broken or incomplete search | Slow/degraded search while rebuilding | Low (disruptive) |
| **Thin Time Machine Snapshots** | Trims local backup snapshots | Recovering disk space | Loses short‑term local "undo" | Low (backups safe) |
| **Speed Up Mail** | Rebuilds the Mail database | A slow Mail app | Mail must be closed; needs Full Disk Access | Low |
| **Background Items** | Manage auto‑starting programs | Faster startup, fewer resources | Removing is permanent | Medium (be careful) |
