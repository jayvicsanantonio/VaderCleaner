// TrashSizeMonitor.swift
// Polls the Trash's total size and notifies when it grows past the user's threshold.

import Foundation

/// Watches the user's Trash and dispatches a "Trash is filling up" notification
/// when its size exceeds `PreferencesStore.trashSizeThresholdGB`, gated by the
/// `notifyTrashSize` toggle and a cooldown so a full Trash alerts at most once
/// per window. The size measurement is injected so the decision logic is
/// unit-testable without walking a real Trash directory.
@MainActor
final class TrashSizeMonitor {

    /// Returns the total bytes currently in the user's Trash. Production walks
    /// `~/.Trash`; tests inject a fixed value.
    typealias SizeReader = @Sendable () async -> Int64

    private let preferences: PreferencesStore
    private let dispatcher: NotificationDispatching
    private let sizeReader: SizeReader
    private let cooldown: TimeInterval
    private let pollInterval: TimeInterval
    private let now: () -> Date

    private var lastFired: Date?
    private var timer: Timer?

    init(
        preferences: PreferencesStore,
        dispatcher: NotificationDispatching,
        sizeReader: @escaping SizeReader = TrashSizeMonitor.measureTrashSize,
        cooldown: TimeInterval = 6 * 60 * 60,
        pollInterval: TimeInterval = 10 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.dispatcher = dispatcher
        self.sizeReader = sizeReader
        self.cooldown = cooldown
        self.pollInterval = pollInterval
        self.now = now
    }

    /// Pure decision: dispatches when the toggle is on, the size is over the
    /// threshold, and the cooldown has elapsed.
    func evaluate(sizeBytes: Int64) {
        guard preferences.notifyTrashSize else { return }
        let thresholdBytes = Int64(max(0, preferences.trashSizeThresholdGB)) * 1_000_000_000
        guard sizeBytes > thresholdBytes else { return }
        if let last = lastFired, now().timeIntervalSince(last) < cooldown { return }

        dispatcher.sendTrashSizeNotification(sizeBytes: sizeBytes)
        lastFired = now()
    }

    /// Begins polling the Trash size on a timer.
    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        self.timer = timer
        Task { await poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() async {
        guard preferences.notifyTrashSize else { return }
        let size = await sizeReader()
        evaluate(sizeBytes: size)
    }

    /// Production size reader: sums the file sizes in the user's Trash off the
    /// main actor. Best-effort — unreadable entries are skipped.
    nonisolated static let measureTrashSize: SizeReader = {
        await Task.detached(priority: .utility) { () -> Int64 in
            let fileManager = FileManager.default
            guard let trash = try? fileManager.url(
                for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ) else { return 0 }
            guard let enumerator = fileManager.enumerator(
                at: trash,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: []
            ) else { return 0 }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
            return total
        }.value
    }
}
