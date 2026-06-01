// LocalSnapshotCounter.swift
// Counts local Time Machine snapshots on the boot volume by parsing `tmutil listlocalsnapshots /`. Listing snapshots is unprivileged, so this runs in-app without the helper.

import Foundation

/// Counts the boot volume's local Time Machine snapshots. The raw command
/// output is injected so unit tests parse canned output without running
/// `tmutil` or depending on the host's snapshot state.
struct LocalSnapshotCounter {

    typealias ListSnapshots = () -> String

    private let listSnapshots: ListSnapshots

    init(listSnapshots: @escaping ListSnapshots = LocalSnapshotCounter.defaultListSnapshots) {
        self.listSnapshots = listSnapshots
    }

    /// The number of local snapshots. `tmutil` prints one
    /// `com.apple.TimeMachine.<date>.local` line per snapshot under a header.
    func count() -> Int {
        listSnapshots()
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains("com.apple.TimeMachine") }
            .count
    }

    /// Runs `/usr/bin/tmutil listlocalsnapshots /` and returns its stdout, or an
    /// empty string if the command can't be run.
    static func defaultListSnapshots() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        // Drain the pipe before waiting: if `tmutil`'s output exceeded the pipe
        // buffer, waiting first would deadlock (the process blocks writing while
        // we block waiting).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
