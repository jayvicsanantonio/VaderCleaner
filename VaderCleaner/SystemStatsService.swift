// SystemStatsService.swift
// Polling data layer behind the Health Monitor — reads CPU, RAM, disk, battery, SMART, and FileVault state from mach/IOKit/diskutil.

import Foundation
import Combine
import Darwin
import IOKit
import IOKit.ps
import os.log

// MARK: - Value types

/// Three coarse buckets the Health Monitor binds color state to. Derived from
/// `usedBytes / totalBytes`; the boundaries live on `MemoryPressureLevel`
/// itself so any new caller (notifications in Prompt 11, the menu bar in
/// Prompt 10) reads the same thresholds the UI does.
enum MemoryPressureLevel: Equatable {
    case nominal
    case fair
    case critical

    /// Threshold at which the bucket flips from `.nominal` to `.fair`.
    /// Centralised so future tuning is one edit — all callers and tests
    /// reference the same constant.
    static let fairThreshold = 0.70

    /// Threshold at which the bucket flips from `.fair` to `.critical`.
    static let criticalThreshold = 0.85

    /// Bucket selection from a unit-interval ratio. Inputs outside `[0, 1]`
    /// are clamped at the boundaries — a transient zero-byte total during
    /// startup must not crash, and an arithmetic overflow upstream must
    /// degrade gracefully rather than mis-report.
    init(usedRatio: Double) {
        let clamped = max(0.0, min(1.0, usedRatio))
        if clamped < Self.fairThreshold {
            self = .nominal
        } else if clamped < Self.criticalThreshold {
            self = .fair
        } else {
            self = .critical
        }
    }
}

/// Snapshot of system memory in bytes plus a derived `pressureLevel`.
///
/// `pressureLevel` is computed on read rather than stored so a manual
/// `MemoryStats(usedBytes:totalBytes:)` in tests stays a one-liner — and so
/// the bucket can never disagree with the byte counts that produced it.
struct MemoryStats: Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    /// Derived pressure level from `usedBytes / totalBytes`. Returns
    /// `.nominal` when `totalBytes == 0` so a transient pre-first-refresh
    /// state doesn't crash on the divide.
    var pressureLevel: MemoryPressureLevel {
        guard totalBytes > 0 else { return .nominal }
        return MemoryPressureLevel(usedRatio: Double(usedBytes) / Double(totalBytes))
    }

    /// All-zeros placeholder used as the published default before the first
    /// refresh has run.
    static let empty = MemoryStats(usedBytes: 0, totalBytes: 0)
}

/// Snapshot of root-volume disk usage in bytes. Used + free does not always
/// equal total on APFS (containers, snapshots, purgeable space), so we store
/// `usedBytes` and `totalBytes` and let callers derive `freeBytes` if they
/// need it — but the spec test pins `usedBytes <= totalBytes`, so we round
/// `usedBytes` to `min(usedBytes, totalBytes)` at read time.
struct DiskStats: Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    static let empty = DiskStats(usedBytes: 0, totalBytes: 0)
}

/// Battery health snapshot from `AppleSmartBattery` IOKit registry. Returned
/// as `nil` from `SystemStatsService.batteryHealth` on machines without an
/// internal battery (Mac mini, Mac Studio, Mac Pro).
struct BatteryStats: Equatable {
    /// Number of full charge cycles the battery has logged.
    let cycleCount: Int

    /// Maximum capacity as a fraction of design capacity (0.0–1.0). 1.0 means
    /// "as good as new"; ~0.80 is Apple's typical service threshold.
    let maxCapacityPercent: Double

    /// Localized condition string from IOKit (`"Normal"`, `"Service Battery"`,
    /// etc.). Treated opaquely by the model; the UI just renders it.
    let condition: String
}

/// SMART status of the boot disk. `.good` corresponds to diskutil's
/// `"Verified"`, `.failing` to `"Failing"`. `.unknown` covers everything
/// else — most relevantly, the case where `diskutil info -plist /` fails or
/// returns no `SMARTStatus` key.
enum SMARTStatus: Equatable {
    case good
    case failing
    case unknown
}

// MARK: - SystemStatsService

/// Publishes live system-health readings on a polling timer.
///
/// All `@Published` properties are read by the Health Monitor (Prompt 9), the
/// menu bar (Prompt 10), and the threshold-based notification dispatcher
/// (Prompt 11). The service intentionally exposes raw value types — no
/// formatting, no thresholds beyond `MemoryPressureLevel` — so each consumer
/// can format / threshold differently without coupling.
///
/// ## Cadence
///
/// One 2-second main-thread timer fans the cheap stats out:
///   - `cpuUsage` (`host_processor_info`)
///   - `ramUsage` (`host_statistics64`)
///   - `diskSpace` (`FileManager.attributesOfFileSystem`)
///   - `batteryHealth` (`AppleSmartBattery` IOKit registry — synchronous,
///     microseconds)
///
/// Subprocess-driven readings (`diskSMARTStatus`, `fileVaultEnabled`) take
/// tens of milliseconds because `diskutil` and `fdesetup` fork + exec. Running
/// them on the same 2-second main-thread tick would jank the UI as soon as
/// anything subscribes. They run on a background `DispatchQueue` and refresh
/// at startup plus once every five minutes — both values are near-static, so
/// sub-second cadence buys nothing.
///
/// ## Testability
///
/// `interval` and `autostart` are injectable. Production calls
/// `SystemStatsService()`; unit tests pass `autostart: false` and call
/// `refresh()` directly to exercise invariants without burning a real timer.
@MainActor
final class SystemStatsService: ObservableObject {

    // MARK: Published readings

    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var ramUsage: MemoryStats = .empty
    @Published private(set) var diskSpace: DiskStats = .empty
    @Published private(set) var batteryHealth: BatteryStats?
    @Published private(set) var diskSMARTStatus: SMARTStatus = .unknown
    @Published private(set) var fileVaultEnabled: Bool = false

    // MARK: Configuration

    /// Tick rate of the cheap-stats timer.
    private let interval: TimeInterval

    /// Slow timer cadence for SMART + FileVault. Five minutes is a compromise:
    /// the values are near-static, but a manual change (toggling FileVault,
    /// hot-swapping a drive) should reflect within a reasonable window without
    /// requiring an explicit refresh action.
    private static let deviceHealthInterval: TimeInterval = 300

    // MARK: State

    private var timer: Timer?
    private var deviceHealthTimer: Timer?
    /// Tracks whether `stop()` has been called more recently than `start()`.
    /// In-flight background subprocess work (SMART, FileVault) hops back to
    /// the main actor *after* potentially tens of milliseconds; if `stop()`
    /// landed in that window, we must not publish the stale result. The flag
    /// gates only the timer-driven and async-hop paths — the synchronous
    /// `refresh()` is still callable directly so unit tests with
    /// `autostart: false` keep working.
    private var isStopped = false
    private let log = OSLog(subsystem: "com.personal.VaderCleaner", category: "SystemStatsService")

    /// Background queue for `Process` invocations. Serial so two ticks can't
    /// race a `diskutil` and an `fdesetup` against each other and confuse
    /// stdout interleaving in any future shared parser.
    private let backgroundQueue = DispatchQueue(label: "com.personal.VaderCleaner.SystemStatsService.background")

    /// Previous CPU tick totals for delta computation. `host_processor_info`
    /// reports cumulative ticks since boot, so usage is `(busy_now -
    /// busy_then) / (total_now - total_then)`. Nil before the first sample;
    /// the first `refresh()` seeds it and publishes `cpuUsage = 0`.
    private var previousCPUTotals: CPUTotals?

    // MARK: Init / lifecycle

    init(interval: TimeInterval = 2.0, autostart: Bool = true) {
        self.interval = interval
        if autostart {
            start()
            // Kick off the slow path immediately so SMART + FileVault are
            // populated by the time the Health Monitor first renders. The
            // timer below schedules subsequent refreshes.
            refreshDeviceHealth()
        }
    }

    deinit {
        // Timers retain their target via the closure capture, but invalidating
        // here is still polite — the run loop will drop them on the next
        // iteration. Without the explicit invalidate, a service that outlives
        // its expected scope (e.g. a leaked test instance) would keep firing.
        timer?.invalidate()
        deviceHealthTimer?.invalidate()
    }

    /// Begins periodic refreshes. Idempotent — calling `start()` on an
    /// already-running service tears down the previous timers first so the
    /// caller can change `interval` semantics without leaking.
    func start() {
        stop()
        isStopped = false
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Timer callbacks fire on whichever queue scheduled them; for
            // `Timer.scheduledTimer` that's the current run loop, which is
            // typically `.main`. We re-enter the main actor explicitly so a
            // future caller starting the service from a background context
            // can't violate the actor isolation.
            Task { @MainActor in
                self?.refresh()
            }
        }
        deviceHealthTimer = Timer.scheduledTimer(
            withTimeInterval: Self.deviceHealthInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDeviceHealth()
            }
        }
    }

    /// Stops all polling. Safe to call repeatedly. Used by tests to verify the
    /// service goes quiet on demand and by the App during teardown.
    func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
        deviceHealthTimer?.invalidate()
        deviceHealthTimer = nil
    }

    // MARK: Cheap stats — refresh

    /// Reads all cheap stats and republishes. Synchronous; safe to call from
    /// the main thread.
    func refresh() {
        cpuUsage = readCPUUsage()
        ramUsage = readMemoryStats()
        diskSpace = readDiskStats()
        batteryHealth = readBatteryStats()
    }

    // MARK: CPU

    private struct CPUTotals {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var busy: UInt64 { user &+ system &+ nice }
        var total: UInt64 { busy &+ idle }
    }

    /// Sums per-CPU tick counters via `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`,
    /// then returns the delta against the previous sample. The first call
    /// seeds the baseline and returns `0` because there is nothing to subtract
    /// against. Subsequent calls return `(busy_delta) / (total_delta)`.
    private func readCPUUsage() -> Double {
        var cpuInfo: processor_info_array_t!
        var numCPUs: natural_t = 0
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            os_log("host_processor_info failed (code=%d)", log: log, type: .error, result)
            return cpuUsage // keep the previously published value rather than spike to 0
        }
        // `host_processor_info` allocates the buffer in our task; we own it.
        // Forgetting the deallocate here would leak a small chunk of vm on
        // every two-second tick — measurable as RSS creep over hours.
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        var totals = CPUTotals(user: 0, system: 0, idle: 0, nice: 0)
        var sumUser: UInt64 = 0
        var sumSystem: UInt64 = 0
        var sumIdle: UInt64 = 0
        var sumNice: UInt64 = 0
        for cpu in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * cpu
            sumUser &+= UInt64(cpuInfo[base + Int(CPU_STATE_USER)])
            sumSystem &+= UInt64(cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            sumIdle &+= UInt64(cpuInfo[base + Int(CPU_STATE_IDLE)])
            sumNice &+= UInt64(cpuInfo[base + Int(CPU_STATE_NICE)])
        }
        totals = CPUTotals(user: sumUser, system: sumSystem, idle: sumIdle, nice: sumNice)

        guard let previous = previousCPUTotals else {
            // First read — seed the baseline and report no usage. The next
            // tick will produce a real number.
            previousCPUTotals = totals
            return 0.0
        }

        let busyDelta = totals.busy &- previous.busy
        let totalDelta = totals.total &- previous.total
        previousCPUTotals = totals

        guard totalDelta > 0 else {
            // Two reads inside the same scheduling quantum — no ticks elapsed.
            // Returning the previously published value avoids a spurious zero.
            return cpuUsage
        }
        let usage = Double(busyDelta) / Double(totalDelta)
        // Clamp defensively — kernel arithmetic is well-behaved but we never
        // want to publish a value the test invariants reject.
        return max(0.0, min(1.0, usage))
    }

    // MARK: Memory

    /// Reads physical memory totals via `host_statistics64(HOST_VM_INFO64)` for
    /// per-region page counts and `host_info(HOST_BASIC_INFO)` for the
    /// physical maximum. "Used" is `active + wired + compressor`, which is
    /// what Activity Monitor's "Memory Used" reports.
    private func readMemoryStats() -> MemoryStats {
        var vmStats = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let vmResult = withUnsafeMutablePointer(to: &vmStats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &vmCount)
            }
        }
        guard vmResult == KERN_SUCCESS else {
            os_log("host_statistics64 failed (code=%d)", log: log, type: .error, vmResult)
            return ramUsage // keep last good value
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(vmStats.active_count)
        let wired = UInt64(vmStats.wire_count)
        let compressed = UInt64(vmStats.compressor_page_count)
        let usedPages = active &+ wired &+ compressed
        let usedBytes = usedPages &* pageSize

        var hostInfo = host_basic_info_data_t()
        var hostCount = mach_msg_type_number_t(
            MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let hostResult = withUnsafeMutablePointer(to: &hostInfo) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(hostCount)) { intPtr in
                host_info(mach_host_self(), HOST_BASIC_INFO, intPtr, &hostCount)
            }
        }
        guard hostResult == KERN_SUCCESS else {
            os_log("host_info failed (code=%d)", log: log, type: .error, hostResult)
            return ramUsage
        }
        // `max_mem` is a 64-bit field on host_basic_info; `memory_size` is the
        // 32-bit legacy alias and overflows above 4 GB. Use `max_mem`.
        let totalBytes = UInt64(hostInfo.max_mem)

        // Cap usedBytes at totalBytes — `active + wired + compressor` can
        // briefly exceed `max_mem` during transient kernel accounting. Capping
        // preserves the test invariant `usedBytes <= totalBytes` and
        // matches what a UI should display anyway.
        let cappedUsed = min(usedBytes, totalBytes)
        return MemoryStats(usedBytes: cappedUsed, totalBytes: totalBytes)
    }

    // MARK: Disk

    /// Reads root-volume capacity via `FileManager.attributesOfFileSystem`.
    /// `/` is the boot volume on every macOS configuration we support.
    private func readDiskStats() -> DiskStats {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            // The system-* keys are documented as `NSNumber` (UInt64-backed).
            // Using `NSNumber.uint64Value` rather than `Int` avoids the
            // signed/unsigned trap on volumes >= 8 EiB (theoretical, but
            // costs nothing).
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            let used = total > free ? total - free : 0
            return DiskStats(usedBytes: used, totalBytes: total)
        } catch {
            os_log("FileManager.attributesOfFileSystem failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            return diskSpace // keep last good
        }
    }

    // MARK: Battery

    /// Reads battery health from the `AppleSmartBattery` IORegistry entry.
    /// Returns `nil` on machines with no internal battery (the matching call
    /// fails silently with `IO_OBJECT_NULL`). The keys read here are stable
    /// across at least the last decade of macOS releases — Apple uses the
    /// same registry for `system_profiler SPPowerDataType`.
    private func readBatteryStats() -> BatteryStats? {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        let cycle = (copyProperty(service: service, key: "CycleCount") as? NSNumber)?.intValue ?? 0
        let maxCap = (copyProperty(service: service, key: "AppleRawMaxCapacity") as? NSNumber)?.doubleValue
            ?? (copyProperty(service: service, key: "MaxCapacity") as? NSNumber)?.doubleValue
            ?? 0
        let designCap = (copyProperty(service: service, key: "DesignCapacity") as? NSNumber)?.doubleValue
            ?? 0
        // Some hardware reports `BatteryHealth` ("Good"/"Fair"/"Poor") under a
        // few different keys depending on macOS version. Try the modern key
        // first, then fall back. An empty string would fail the test invariant
        // (`condition.isEmpty == false`) so we substitute `"Unknown"` on
        // outright misses.
        let condition = (copyProperty(service: service, key: "BatteryHealthCondition") as? String)
            ?? (copyProperty(service: service, key: "BatteryHealth") as? String)
            ?? "Unknown"

        let healthFraction = designCap > 0 ? min(1.0, maxCap / designCap) : 0.0
        return BatteryStats(
            cycleCount: cycle,
            maxCapacityPercent: healthFraction,
            condition: condition.isEmpty ? "Unknown" : condition
        )
    }

    /// Thin wrapper around `IORegistryEntryCreateCFProperty` that returns the
    /// CF object as `Any?`. Centralised so each property read above is one
    /// line and we don't repeat the bridging dance.
    private func copyProperty(service: io_service_t, key: String) -> Any? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        return unmanaged.takeRetainedValue() as Any
    }

    // MARK: Device health (SMART, FileVault) — slow path

    /// Refreshes SMART and FileVault state by shelling out to `diskutil` and
    /// `fdesetup` on a background queue, then publishing back on the main
    /// actor. Safe to call from any context. Errors fall back to `.unknown`
    /// and `false` so a transient failure doesn't flicker existing UI between
    /// stale and zero values.
    func refreshDeviceHealth() {
        backgroundQueue.async {
            // Static methods read SMART and FileVault from subprocesses; no
            // `self` capture is required on the background hop. We re-acquire
            // a weak reference inside the MainActor hop so a service that has
            // been deallocated or stopped before the subprocesses returned
            // doesn't try to publish stale results.
            let smart = Self.readSMARTStatus()
            let fv = Self.readFileVaultEnabled()
            Task { @MainActor [weak self] in
                guard let self = self, !self.isStopped else { return }
                self.diskSMARTStatus = smart
                self.fileVaultEnabled = fv
            }
        }
    }

    /// Runs `/usr/sbin/diskutil info -plist /` and parses `SMARTStatus` from
    /// the resulting property list. `"Verified"` is the value Apple Silicon
    /// internal NVMe disks report; older Intel SATA disks report `"Verified"`
    /// or `"Failing"`. Anything else, or any subprocess failure, reduces to
    /// `.unknown` — the UI layer treats `.unknown` as "no opinion" rather
    /// than alarming the user.
    nonisolated private static func readSMARTStatus() -> SMARTStatus {
        let log = OSLog(subsystem: "com.personal.VaderCleaner", category: "SystemStatsService")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discard stderr so a noisy warning doesn't spam Console.app from us.
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                os_log("diskutil exited %d", log: log, type: .error, process.terminationStatus)
                return .unknown
            }
            guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
                  let status = plist["SMARTStatus"] as? String else {
                return .unknown
            }
            switch status {
            case "Verified":
                return .good
            case "Failing":
                return .failing
            default:
                return .unknown
            }
        } catch {
            os_log("diskutil invocation failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            return .unknown
        }
    }

    /// Runs `/usr/bin/fdesetup status` and parses the first line of stdout.
    /// `fdesetup` prints `"FileVault is On."` or `"FileVault is Off."` on the
    /// first line; we look for the literal `" On."` substring so future
    /// trailing notes (the encryption-progress percentage during the initial
    /// encryption phase, for example) don't trip us up.
    nonisolated private static func readFileVaultEnabled() -> Bool {
        let log = OSLog(subsystem: "com.personal.VaderCleaner", category: "SystemStatsService")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return false
            }
            return output.contains("FileVault is On.")
        } catch {
            os_log("fdesetup invocation failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            return false
        }
    }
}
