# Performance — User Guide

The **Performance** section keeps your Mac running smoothly by handling routine
upkeep that macOS doesn't always do on its own. Think of it as a tune‑up for your
computer: a handful of safe, well‑understood maintenance jobs you can run with a
single click.

This guide explains, in plain language, what the section shows you, what each task
actually does, and the trade‑offs of running it — so you can decide what's worth
doing and when.

---

## Table of contents

- [How the section is laid out](#how-the-section-is-laid-out)
- [The summary cards](#the-summary-cards)
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

When you open **Performance**, you'll see two views:

1. **The dashboard** (the first thing you see). A set of *summary cards* shows
   what's worth a look right now, and each card's **Review** button opens the
   manager at the matching list.

2. **The Performance Manager** (**View All Tasks** on the dashboard), organized
   with a list on the left:
   - **Login Items** — apps set to open when you log in.
   - **Background Items** — helper programs that start automatically.
   - **Maintenance Tasks** — every task with a checkbox and a colorful icon. Tick
     the ones you want, and the bar at the bottom shows how many are selected, with
     a **Run** button that runs them together.

The search field filters the list you're looking at. **Select All**, **Run**, and
**Remove** only ever reach the rows on screen: anything a search is hiding stays
out of it, and the footer's count is what will be acted on.

The lists are re-read each time you come back to the section or to the app, so
something you uninstalled elsewhere doesn't linger. Nothing runs until you click a
button.

> **A note on permissions.** Most of these tasks change system‑level settings, so
> macOS requires administrator rights. VaderCleaner performs them through a small,
> signed background helper that has permission to do this safely. You may be asked
> to approve the helper the first time. The one exception is **Speed Up Mail**,
> which works at the user level and needs the Mail app to be closed.

---

## The summary cards

Only the categories with something to look at get a card:

| Card | When it appears | What **Review** does |
| --- | --- | --- |
| **You Have N Login Items** | VaderCleaner is set to open at login | Opens Login Items |
| **N Background Items Found** | Apps or helpers start automatically with your Mac | Opens Background Items |
| **N Maintenance Tasks Recommended** | Routine tasks haven't run in over a week | Opens Maintenance Tasks with the due ones ticked and marked **Due** |

The maintenance count covers routine upkeep only: maintenance scripts, flushing DNS,
and speeding up Mail. The other tasks wait until you have a reason to run them.
Reindex Spotlight in particular is never recommended on a schedule, because erasing
the index makes search worse until it's rebuilt.

If Mail has no data to rebuild, or you've declined Full Disk Access, Speed Up Mail
stops counting as due for another week rather than holding the card up.

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
VaderCleaner won't suggest it; it runs only when you pick it.

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
- **Your backup disk is not touched** — only the temporary local copies are
  thinned, and macOS only removes what it safely can. The result line says how many
  it removed, which may be none.

**Cons**
- **Local snapshots may be your only recent restore points** while your backup disk
  is away. Once thinned, changes made since the last backup to that disk can't be
  restored from them.
- Does nothing if you don't use Time Machine.

**Does this affect my backup disk or encryption?** No.
- **Your backup disk is safe.** This only thins the *local* snapshots stored on your
  Mac's internal disk. The full backup history on your external or network Time
  Machine drive is never touched — and macOS only removes what it can safely
  remove. Under the hood, this simply asks macOS to reclaim space
  (`tmutil thinlocalsnapshots`); it does not delete specific backups by hand.
- **Encryption is unchanged.** If FileVault is on, your disk and the snapshots on
  it stay fully encrypted — thinning doesn't decrypt anything. If your Time Machine
  backup drive is encrypted, that's a separate disk this task doesn't touch, so its
  encryption is unaffected too.

**Bottom line.** A way to recover disk space if you use Time Machine. Your backup
disk stays intact and nothing is decrypted — the cost is losing recent local restore
points until macOS makes new snapshots, so back up first if your backup disk has
been away.

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
- **Mail must be closed** while this runs. If Mail is open, VaderCleaner asks you to
  quit it and leaves the database alone.
- Requires that the app can read your Mail data, which may need **Full Disk Access**
  granted to VaderCleaner in System Settings → Privacy & Security.
- The first time you reopen Mail afterward, it may take a moment to settle.

**Bottom line.** Worth it if Mail feels slow. Just quit Mail first.

---

## Background Items

In the Performance Manager, **Background Items** lists programs that start
automatically, often installed alongside other apps. Too many can slow down startup
and use resources all day. For the ones installed just for you, you can:

- **Turn one off** with its switch, so it stops running and stays off across logins.
  Turn it back on the same way. A leftover file with nothing to run has no switch.
- **Remove** it. VaderCleaner stops it and moves its file to the Trash, so you can
  put the file back if you change your mind. The confirmation names what will go.

If something can't be removed, the rest of your selection still goes, and whatever
failed stays ticked so you can try again.

**Items installed for all users are review‑only.** These are listed under their own
heading, usually from apps you installed. VaderCleaner doesn't remove them, because
that can break the app they came with. **Open System Settings** takes you to where
macOS lets you turn them off; uninstalling the app removes them.

**A word of caution.** Some background items are needed by apps you rely on (for
example, cloud‑storage syncing or keyboard/mouse utilities). If you're not sure what
something is, turn it off rather than removing it, and see whether anything you use
stops working.

---

## Frequently asked questions

**Will any of these delete my files?**
No. None of these tasks touch your documents, photos, or emails. They clear caches,
run housekeeping, trim *temporary* backup snapshots, and rebuild *indexes* — not
your actual data.

**Do I need to run these regularly?**
Not really. Most are "run it when you notice a specific problem" tools rather than
chores. The dashboard nudges you about routine upkeep once it's over a week old.

**Why does it ask for a password or approval?**
Several tasks change system‑level settings, which macOS protects. VaderCleaner uses
a small signed helper to do this safely; approving it is a one‑time step.

**Can I undo a task?**
There's nothing to undo for most of them. Reindex Spotlight and Speed Up Mail simply
rebuild their indexes. Thinned snapshots can't be brought back. A removed Background
Item's file is in the Trash; put it back and it loads again at your next login.

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
| **Thin Time Machine Snapshots** | Trims local backup snapshots | Recovering disk space | Loses recent local restore points | Low (backup disk untouched) |
| **Speed Up Mail** | Rebuilds the Mail database | A slow Mail app | Mail must be closed; needs Full Disk Access | Low |
| **Background Items** | Manage auto‑starting programs | Faster startup, fewer resources | An app may need what you removed | Medium (be careful) |
