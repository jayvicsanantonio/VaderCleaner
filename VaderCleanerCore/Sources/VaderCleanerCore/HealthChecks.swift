// HealthChecks.swift
// The Health Monitor's checks and verdict in plain language: storage, battery, drive, and encryption each with a status word and detail, plus the summary that names what to watch and the live-load labels.

import Foundation

/// One long-lived health check: something that changes over weeks or months
/// and may need the user to act, as opposed to the moment-to-moment load the
/// "Right now" tiles show.
public struct HealthCheck: Equatable, Sendable, Identifiable {

    public enum Kind: Sendable {
        case storage
        case battery
        case drive
        case encryption
    }

    /// One scale for every check, so a color and a word mean the same thing
    /// on every row.
    public enum Status: Sendable {
        case good
        case watch
        case act
        case unknown

        public var label: String {
            switch self {
            case .good: return String(localized: "Good", bundle: .module, comment: "Health check status: nothing to do.")
            case .watch: return String(localized: "Watch", bundle: .module, comment: "Health check status: worth keeping an eye on.")
            case .act: return String(localized: "Act now", bundle: .module, comment: "Health check status: needs action.")
            case .unknown: return String(localized: "Unknown", bundle: .module, comment: "Health check status: not reported or not read yet.")
            }
        }
    }

    public let kind: Kind
    public let status: Status
    public let title: String
    public let detail: String
    /// How full the disk is, for the storage row's bar. `nil` on other rows.
    public let ratio: Double?
    /// How the verdict names this check when it needs watching, e.g. "your
    /// disk is 81% full". `nil` while the check is fine.
    let concern: String?

    public var id: Kind { kind }
}

/// What the verdict offers to do about the problem it names.
public enum HealthAction: Equatable, Sendable {
    case freeUpSpace
}

/// The verdict at the top of the Health Monitor: a headline, the reason in a
/// sentence, and the one action that helps, if there is one.
public struct HealthSummary: Equatable, Sendable {
    public let headline: String
    public let reason: String
    public let action: HealthAction?
}

/// Builds the checks and the verdict. Pure functions over the service's
/// readings, so the rules are tested without live telemetry.
public enum HealthChecks {

    static func checks(disk: DiskStats, battery: BatteryAvailability, smart: SMARTStatus, fileVault: FileVaultState) -> [HealthCheck] {
        [storageCheck(disk), batteryCheck(battery), driveCheck(smart), encryptionCheck(fileVault)].compactMap { $0 }
    }

    // MARK: - Checks

    private static func storageCheck(_ disk: DiskStats) -> HealthCheck {
        let title = String(localized: "Storage", bundle: .module, comment: "Health check title: free disk space.")
        guard disk.totalBytes > 0 else {
            return HealthCheck(kind: .storage, status: .unknown, title: title, detail: checking, ratio: nil, concern: nil)
        }
        let ratio = HealthMonitorViewModel.diskUsageRatio(disk)
        // The same thresholds the verdict's disk tier uses, so a row and the
        // verdict above it can't disagree.
        let status: HealthCheck.Status
        switch HealthMonitorViewModel.diskColor(for: disk) {
        case .green: status = .good
        case .yellow: status = .watch
        case .red: status = .act
        case .gray: status = .unknown
        }
        let free = disk.totalBytes > disk.usedBytes ? disk.totalBytes - disk.usedBytes : 0
        let detail = String.localizedStringWithFormat(
            String(localized: "%@ free of %@", bundle: .module, comment: "Storage check detail: free bytes of total bytes."),
            SystemStatsFormatters.byteString(free),
            SystemStatsFormatters.byteString(disk.totalBytes)
        )
        let concern = status == .good ? nil : String.localizedStringWithFormat(
            String(localized: "your disk is %d%% full", bundle: .module, comment: "Health verdict concern: disk fullness percentage."),
            Int((ratio * 100).rounded())
        )
        return HealthCheck(kind: .storage, status: status, title: title, detail: detail, ratio: ratio, concern: concern)
    }

    /// `nil` on a Mac with no internal battery: there is nothing to check.
    private static func batteryCheck(_ availability: BatteryAvailability) -> HealthCheck? {
        let title = String(localized: "Battery", bundle: .module, comment: "Health check title: battery health.")
        switch availability {
        case .absent:
            return nil
        case .unknown:
            return HealthCheck(kind: .battery, status: .unknown, title: title, detail: checking, ratio: nil, concern: nil)
        case .present(let stats):
            let status = batteryStatus(stats.condition)
            let concern: String?
            switch status {
            case .act: concern = String(localized: "your battery needs service", bundle: .module, comment: "Health verdict concern: battery needs service.")
            case .watch: concern = String(localized: "your battery is wearing out", bundle: .module, comment: "Health verdict concern: battery capacity is fading.")
            case .good, .unknown: concern = nil
            }
            return HealthCheck(kind: .battery, status: status, title: title, detail: batteryDetail(stats), ratio: nil, concern: concern)
        }
    }

    /// An unreported condition is unknown rather than a warning: there's no
    /// evidence of a problem to warn about.
    private static func batteryStatus(_ condition: String) -> HealthCheck.Status {
        switch condition {
        case "Good", "Normal":
            return .good
        case "Service Battery", "Service Recommended", "Replace Soon", "Replace Now", "Permanent Failure":
            return .act
        case "Unknown":
            return .unknown
        default:
            return .watch
        }
    }

    /// Capacity paired with cycles, since a cycle count alone means nothing to
    /// most people. A capacity of 0 means none could be read.
    private static func batteryDetail(_ stats: BatteryStats) -> String {
        let cycles = stats.cycleCount == 1
            ? String(localized: "1 cycle", bundle: .module, comment: "Battery check detail: one charge cycle.")
            : String.localizedStringWithFormat(
                String(localized: "%d cycles", bundle: .module, comment: "Battery check detail: charge cycle count."),
                stats.cycleCount
            )
        guard stats.maxCapacityPercent > 0 else { return cycles }
        return String.localizedStringWithFormat(
            String(localized: "%d%% of original capacity · %@", bundle: .module, comment: "Battery check detail: capacity percentage, then the cycle count."),
            Int((min(1, stats.maxCapacityPercent) * 100).rounded()),
            cycles
        )
    }

    private static func driveCheck(_ smart: SMARTStatus) -> HealthCheck {
        let title = String(localized: "Drive condition", bundle: .module, comment: "Health check title: the drive's own SMART self-assessment.")
        switch smart {
        case .good:
            return HealthCheck(
                kind: .drive, status: .good, title: title,
                detail: String(localized: "No problems reported by the drive", bundle: .module, comment: "Drive check detail: SMART verified."),
                ratio: nil, concern: nil
            )
        case .failing:
            return HealthCheck(
                kind: .drive, status: .act, title: title,
                detail: String(localized: "The drive reports it may fail — back up now", bundle: .module, comment: "Drive check detail: SMART failing."),
                ratio: nil,
                concern: String(localized: "your drive reports it may fail", bundle: .module, comment: "Health verdict concern: SMART failing.")
            )
        case .unknown:
            return HealthCheck(
                kind: .drive, status: .unknown, title: title,
                detail: String(localized: "This drive doesn't report its condition", bundle: .module, comment: "Drive check detail: no SMART reading."),
                ratio: nil, concern: nil
            )
        }
    }

    private static func encryptionCheck(_ fileVault: FileVaultState) -> HealthCheck {
        let title = String(localized: "Encryption", bundle: .module, comment: "Health check title: FileVault.")
        switch fileVault {
        case .on:
            return HealthCheck(
                kind: .encryption, status: .good, title: title,
                detail: String(localized: "FileVault is on", bundle: .module, comment: "Encryption check detail: FileVault on."),
                ratio: nil, concern: nil
            )
        case .off:
            return HealthCheck(
                kind: .encryption, status: .watch, title: title,
                detail: String(localized: "FileVault is off, so your files aren't encrypted", bundle: .module, comment: "Encryption check detail: FileVault off."),
                ratio: nil,
                concern: String(localized: "FileVault is off", bundle: .module, comment: "Health verdict concern: FileVault off.")
            )
        case .unknown:
            return HealthCheck(kind: .encryption, status: .unknown, title: title, detail: checking, ratio: nil, concern: nil)
        }
    }

    private static var checking: String {
        String(localized: "Checking…", bundle: .module, comment: "Health check detail before the first reading.")
    }

    // MARK: - Verdict

    /// The headline follows the overall verdict tier; the reason names every
    /// check that needs watching, so the verdict never says "attention"
    /// without saying what for. `verdict` is `nil` until the disk is measured.
    static func summary(verdict: MacHealthStatus?, checks: [HealthCheck]) -> HealthSummary {
        guard let verdict else {
            return HealthSummary(
                headline: String(localized: "Checking your Mac…", bundle: .module, comment: "Health verdict headline before the first reading."),
                reason: String(localized: "This only takes a moment.", bundle: .module, comment: "Health verdict reason before the first reading."),
                action: nil
            )
        }
        let concerns = checks.compactMap(\.concern)
        let reason: String
        switch concerns.count {
        case 0:
            reason = String(localized: "Everything we check looks good.", bundle: .module, comment: "Health verdict reason: no concerns.")
        case 1:
            reason = String.localizedStringWithFormat(
                String(localized: "One thing to watch: %@.", bundle: .module, comment: "Health verdict reason: one concern, e.g. 'your disk is 81% full'."),
                concerns[0]
            )
        default:
            reason = String.localizedStringWithFormat(
                String(localized: "%d things to watch: %@.", bundle: .module, comment: "Health verdict reason: several concerns joined as a list."),
                concerns.count,
                ListFormatter.localizedString(byJoining: concerns)
            )
        }
        let storageNeedsSpace = checks.contains { $0.kind == .storage && ($0.status == .watch || $0.status == .act) }
        return HealthSummary(headline: headline(for: verdict), reason: reason, action: storageNeedsSpace ? .freeUpSpace : nil)
    }

    private static func headline(for verdict: MacHealthStatus) -> String {
        switch verdict {
        case .excellent, .good:
            return String(localized: "Your Mac is healthy", bundle: .module, comment: "Health verdict headline: good or excellent.")
        case .fair, .requiresAttention:
            return String(localized: "Your Mac needs some attention", bundle: .module, comment: "Health verdict headline: fair or requires attention.")
        case .critical:
            return String(localized: "Your Mac needs attention now", bundle: .module, comment: "Health verdict headline: critical.")
        }
    }

    // MARK: - Right now

    static func memoryLoadLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .nominal: return String(localized: "No memory pressure", bundle: .module, comment: "Memory tile label: nominal pressure.")
        case .fair: return String(localized: "Some memory pressure", bundle: .module, comment: "Memory tile label: fair pressure.")
        case .critical: return String(localized: "High memory pressure", bundle: .module, comment: "Memory tile label: critical pressure.")
        }
    }

    /// Words for the CPU load. The top two edges are the CPU color
    /// thresholds, so the label and the tile's color change together.
    static func cpuLoadLabel(_ usage: Double) -> String {
        let ratio = HealthMonitorViewModel.cpuRatio(usage)
        if ratio < 0.5 { return String(localized: "Light load", bundle: .module, comment: "CPU tile label: under half busy.") }
        if ratio < HealthMonitorViewModel.cpuWarningThreshold {
            return String(localized: "Moderate load", bundle: .module, comment: "CPU tile label: half to warning threshold.")
        }
        if ratio < HealthMonitorViewModel.cpuCriticalThreshold {
            return String(localized: "Heavy load", bundle: .module, comment: "CPU tile label: warning to critical threshold.")
        }
        return String(localized: "Maxed out", bundle: .module, comment: "CPU tile label: at or above the critical threshold.")
    }

    /// The footer's one line of system facts. The chip is left out when it
    /// couldn't be read.
    static func systemLine(chip: String, os: String, uptime: String) -> String {
        let up = String.localizedStringWithFormat(
            String(localized: "Up %@", bundle: .module, comment: "Health footer: system uptime, e.g. 'Up 2d 17h'."),
            uptime
        )
        return ([chip, os, up].filter { !$0.isEmpty }).joined(separator: " · ")
    }
}
