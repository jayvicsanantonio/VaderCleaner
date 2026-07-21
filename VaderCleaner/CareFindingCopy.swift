// CareFindingCopy.swift
// Deterministic plain-language catalog for care-plan findings: titles, explanations, safety lines, action verbs, and formatted metrics.

import Foundation

/// The hand-written copy behind every care-plan card, keyed by finding kind.
/// Written for people who don't know what a cache is: each entry says what
/// was found, why it matters, and what happens if they act — in everyday
/// words. This catalog is always what renders; Apple Intelligence
/// explanations only ever augment it in a popover.
enum CareFindingCopy {

    /// Finder-matching file-style formatter, shared for the process lifetime
    /// (construction is comparatively expensive, the formatter is stateless).
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        return formatter
    }()

    /// Human-readable byte string ("2.3 GB"), matching how Finder reports
    /// sizes — which is what users compare our numbers to.
    static func formattedBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// Card headline, one per kind.
    static func title(for kind: CareFinding.Kind) -> String {
        switch kind {
        case .threats:
            return String(localized: "Threats found", comment: "Care card title: malware was detected.")
        case .lowDiskSpace:
            return String(localized: "Your disk is getting full", comment: "Care card title: low free disk space.")
        case .junkCleanup:
            return String(localized: "Junk your Mac doesn't need", comment: "Care card title: system junk (caches, logs).")
        case .duplicates:
            return String(localized: "Duplicate files", comment: "Care card title: byte-identical file copies.")
        case .largeOldFiles:
            return String(localized: "Large & forgotten files", comment: "Care card title: big or long-unopened files.")
        case .unusedApps:
            return String(localized: "Apps you never open", comment: "Care card title: long-unused applications.")
        case .appLeftovers:
            return String(localized: "Files left behind by old apps", comment: "Care card title: orphaned support files of uninstalled apps.")
        case .installers:
            return String(localized: "Finished installers", comment: "Care card title: leftover .dmg/.pkg installer files.")
        case .appUpdates:
            return String(localized: "App updates available", comment: "Care card title: newer app versions exist.")
        case .maintenanceDue:
            return String(localized: "Routine tune-up due", comment: "Care card title: maintenance tasks not run recently.")
        case .browserPrivacy:
            return String(localized: "Browsing traces", comment: "Care card title: browser cookies/history counts.")
        case .loginItems:
            return String(localized: "Apps that start with your Mac", comment: "Care card title: login items list.")
        case .similarImages:
            return String(localized: "Similar photos", comment: "Care card title: near-duplicate images.")
        case .downloads:
            return String(localized: "Old downloads", comment: "Care card title: forgotten files in the Downloads folder.")
        case .unsupportedApps:
            return String(localized: "Apps that won't run", comment: "Care card title: apps incompatible with this macOS.")
        case .extensions:
            return String(localized: "Browser & app extensions", comment: "Care card title: installed extensions and plug-ins.")
        case .backgroundItems:
            return String(localized: "Items running in the background", comment: "Care card title: launch agents/daemons.")
        }
    }

    /// One- or two-sentence explanation: what this is and why it matters,
    /// in words a non-technical user can act on.
    static func explanation(for kind: CareFinding.Kind) -> String {
        switch kind {
        case .threats:
            return String(
                localized: "Files matching known malware were found on your Mac. Removing them protects your Mac and your data.",
                comment: "Care card explanation for detected threats."
            )
        case .lowDiskSpace:
            return String(
                localized: "Your startup disk is almost full, and a full disk slows everything down. Freeing up space will help your Mac feel faster.",
                comment: "Care card explanation for low disk space."
            )
        case .junkCleanup:
            return String(
                localized: "Temporary files, caches, and logs your Mac collects over time. It rebuilds anything it needs, so clearing them is safe.",
                comment: "Care card explanation for system junk."
            )
        case .duplicates:
            return String(
                localized: "Exact copies of files in your Downloads folder. The original is always kept — only the extra copies go.",
                comment: "Care card explanation for duplicate files."
            )
        case .largeOldFiles:
            return String(
                localized: "Big files you haven't opened in a long time. Have a look — you may not need them anymore.",
                comment: "Care card explanation for large and old files."
            )
        case .unusedApps:
            return String(
                localized: "Apps you haven't opened in months. Removing one frees up space, and you can always install it again later.",
                comment: "Care card explanation for unused apps."
            )
        case .appLeftovers:
            return String(
                localized: "Settings and support files left behind by apps that are no longer on your Mac. The apps are gone; these files just take up space.",
                comment: "Care card explanation for app leftovers."
            )
        case .installers:
            return String(
                localized: "Installer files that already did their job. Once an app is installed, its installer isn't needed anymore.",
                comment: "Care card explanation for leftover installers."
            )
        case .appUpdates:
            return String(
                localized: "Newer versions of some of your apps are ready. Updates bring fixes and security improvements.",
                comment: "Care card explanation for available app updates."
            )
        case .maintenanceDue:
            return String(
                localized: "Routine housekeeping your Mac benefits from every so often, like refreshing system caches. It runs in the background and takes a moment.",
                comment: "Care card explanation for due maintenance tasks."
            )
        case .browserPrivacy:
            return String(
                localized: "Cookies, history, and other traces your browsers keep about where you've been. Worth a look, especially if you share this Mac.",
                comment: "Care card explanation for browser privacy data."
            )
        case .loginItems:
            return String(
                localized: "These apps open by themselves every time you turn on your Mac. Fewer of them usually means a quicker start.",
                comment: "Care card explanation for login items."
            )
        case .similarImages:
            return String(
                localized: "Photos that look nearly the same — bursts and near-duplicates. Keep the best shot and clear the rest.",
                comment: "Care card explanation for similar images."
            )
        case .downloads:
            return String(
                localized: "Files in your Downloads folder you likely opened once and forgot. Clearing them out frees up space.",
                comment: "Care card explanation for old downloads."
            )
        case .unsupportedApps:
            return String(
                localized: "Apps that aren't compatible with this version of macOS — they can't open, so removing them just reclaims space.",
                comment: "Care card explanation for unsupported apps."
            )
        case .extensions:
            return String(
                localized: "Extensions and plug-ins added to your browsers and apps. Worth a look — disable anything you don't recognize.",
                comment: "Care card explanation for extensions."
            )
        case .backgroundItems:
            return String(
                localized: "Helpers and agents that run quietly in the background. Fewer of them can mean a lighter, faster Mac.",
                comment: "Care card explanation for background items."
            )
        }
    }

    /// The safety pill under each card — the single line that tells a
    /// non-technical user whether acting is risk-free.
    static func safetyLine(for actionability: CareActionability) -> String {
        switch actionability {
        case .preApproved:
            return String(
                localized: "Safe to clean — your Mac can rebuild anything it needs.",
                comment: "Care card safety line for pre-approved findings."
            )
        case .optIn:
            return String(
                localized: "These are your files — nothing is removed unless you choose it.",
                comment: "Care card safety line for opt-in findings."
            )
        case .informational:
            return String(
                localized: "Just so you know — nothing here will be removed.",
                comment: "Care card safety line for informational findings."
            )
        }
    }

    /// Short verb for the card's action affordance.
    static func actionVerb(for kind: CareFinding.Kind) -> String {
        switch kind {
        case .threats:
            return String(localized: "Remove", comment: "Care card action verb for threats.")
        case .lowDiskSpace:
            return String(localized: "See What's Taking Space", comment: "Care card action verb for low disk space.")
        case .junkCleanup:
            return String(localized: "Clean Up", comment: "Care card action verb for junk.")
        case .duplicates:
            return String(localized: "Remove Copies", comment: "Care card action verb for duplicates.")
        case .largeOldFiles, .unusedApps, .appLeftovers, .installers, .browserPrivacy,
             .similarImages, .downloads, .unsupportedApps:
            return String(localized: "Review", comment: "Care card action verb for opt-in findings.")
        case .appUpdates:
            return String(localized: "Update", comment: "Care card action verb for app updates.")
        case .maintenanceDue:
            return String(localized: "Tune Up", comment: "Care card action verb for maintenance.")
        case .loginItems, .extensions, .backgroundItems:
            return String(localized: "Have a Look", comment: "Care card action verb for review-only findings.")
        }
    }

    /// The scanning checklist's per-domain result line, composed from the
    /// findings that domain's units landed. One plain sentence: what was
    /// found, or an explicit all-clear so silence never reads as "unchecked".
    static func domainResultLine(_ domain: CareDomain, findings: [CareFinding]) -> String {
        let relevant = findings.filter { $0.kind.unit.domain == domain && !$0.isEmpty }
        switch domain {
        case .systemJunk:
            guard let junk = relevant.first(where: { $0.kind == .junkCleanup }) else {
                return String(localized: "No junk worth clearing", comment: "Checklist all-clear line for the Cleanup domain.")
            }
            return String.localizedStringWithFormat(
                String(localized: "%@ of junk to clear — all safe", comment: "Checklist result line for the Cleanup domain (bytes)."),
                formattedBytes(junk.reclaimableBytes)
            )
        case .myClutter:
            let bytes = relevant.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
            guard bytes > 0 else {
                return String(localized: "No clutter found", comment: "Checklist all-clear line for the My Clutter domain.")
            }
            return String.localizedStringWithFormat(
                String(localized: "%@ of clutter to sort through", comment: "Checklist result line for the My Clutter domain (bytes)."),
                formattedBytes(bytes)
            )
        case .malware:
            guard let threats = relevant.first(where: { $0.kind == .threats }) else {
                return String(localized: "No threats found", comment: "Checklist all-clear line for the Protection domain.")
            }
            return metric(for: threats)
        case .browserPrivacy:
            guard let traces = relevant.first(where: { $0.kind == .browserPrivacy }) else {
                return String(localized: "No browsing traces found", comment: "Checklist all-clear line for the Browser Privacy domain.")
            }
            return String.localizedStringWithFormat(
                String(localized: "%d browsing traces", comment: "Checklist result line for the Browser Privacy domain (item count)."),
                traces.itemCount
            )
        case .applications:
            var parts: [String] = []
            if let updates = relevant.first(where: { $0.kind == .appUpdates }) {
                parts.append(String.localizedStringWithFormat(
                    String(localized: "%d updates", comment: "Checklist fragment: available update count."),
                    updates.itemCount
                ))
            }
            if let unused = relevant.first(where: { $0.kind == .unusedApps }) {
                parts.append(String.localizedStringWithFormat(
                    String(localized: "%d unused apps", comment: "Checklist fragment: unused app count."),
                    unused.itemCount
                ))
            }
            if let leftovers = relevant.first(where: { $0.kind == .appLeftovers }) {
                parts.append(String.localizedStringWithFormat(
                    String(localized: "%d apps left files behind", comment: "Checklist fragment: leftover group count."),
                    leftovers.itemCount
                ))
            }
            if let installers = relevant.first(where: { $0.kind == .installers }) {
                parts.append(String.localizedStringWithFormat(
                    String(localized: "%d old installers", comment: "Checklist fragment: leftover installer count."),
                    installers.itemCount
                ))
            }
            if let unsupported = relevant.first(where: { $0.kind == .unsupportedApps }) {
                parts.append(String.localizedStringWithFormat(
                    String(localized: "%d won't run", comment: "Checklist fragment: unsupported app count."),
                    unsupported.itemCount
                ))
            }
            if let extensions = relevant.first(where: { $0.kind == .extensions }) {
                parts.append(String.localizedStringWithFormat(
                    String(localized: "%d extensions", comment: "Checklist fragment: extension count."),
                    extensions.itemCount
                ))
            }
            guard !parts.isEmpty else {
                return String(localized: "Your apps look good", comment: "Checklist all-clear line for the Applications domain.")
            }
            return parts.joined(separator: " · ")
        case .performance:
            var parts: [String] = []
            if let due = relevant.first(where: { $0.kind == .maintenanceDue }) {
                parts.append(metric(for: due))
            }
            if let items = relevant.first(where: { $0.kind == .loginItems }) {
                parts.append(metric(for: items))
            }
            if let background = relevant.first(where: { $0.kind == .backgroundItems }) {
                parts.append(metric(for: background))
            }
            guard !parts.isEmpty else {
                return String(localized: "Nothing due right now", comment: "Checklist all-clear line for the Performance domain.")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// The big number on a card: bytes for reclaimable-space findings,
    /// pluralized counts for count findings, percent-full for disk space.
    static func metric(for finding: CareFinding) -> String {
        switch finding.payload {
        case .junk, .duplicates, .largeOldFiles, .unusedApps, .appLeftovers, .installers,
             .similarImages, .downloads:
            return formattedBytes(finding.reclaimableBytes)
        case .threats:
            return String.localizedStringWithFormat(
                String(localized: "%d threats found", comment: "Care card metric: threat count."),
                finding.itemCount
            )
        case .appUpdates:
            return String.localizedStringWithFormat(
                String(localized: "%d updates available", comment: "Care card metric: update count."),
                finding.itemCount
            )
        case .loginItems:
            return String.localizedStringWithFormat(
                String(localized: "%d login items", comment: "Care card metric: login item count."),
                finding.itemCount
            )
        case .maintenanceDue:
            return String.localizedStringWithFormat(
                String(localized: "%d tasks due", comment: "Care card metric: due maintenance task count."),
                finding.itemCount
            )
        case .browserPrivacy:
            return String.localizedStringWithFormat(
                String(localized: "%d items", comment: "Care card metric: browser privacy item count."),
                finding.itemCount
            )
        case .unsupportedApps:
            return String.localizedStringWithFormat(
                String(localized: "%d incompatible apps", comment: "Care card metric: unsupported app count."),
                finding.itemCount
            )
        case .extensions:
            return String.localizedStringWithFormat(
                String(localized: "%d extensions", comment: "Care card metric: extension count."),
                finding.itemCount
            )
        case .backgroundItems:
            return String.localizedStringWithFormat(
                String(localized: "%d background items", comment: "Care card metric: background item count."),
                finding.itemCount
            )
        case .lowDiskSpace(let stats):
            let percent = Int((HealthMonitorViewModel.diskUsageRatio(stats) * 100).rounded())
            return String.localizedStringWithFormat(
                String(localized: "%d%% full", comment: "Care card metric: disk percent full."),
                percent
            )
        }
    }
}
