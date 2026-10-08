// BrewRunning.swift
// The single seam through which every `brew` invocation flows — a buffered form for JSON/query commands and a streamed form for long, cancellable operations.

import Foundation

/// Captured result of a buffered `brew` invocation.
struct BrewResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

/// Abstraction over `brew` execution so the view model can be unit-tested with
/// stub responses and fixture output, with no real Homebrew on the machine.
///
/// Two flavors by design: `runCapturing` buffers the full output of a short
/// query (`list`, `outdated --json=v2`, `leaves`, `uses`, `cleanup -n`);
/// `runStreaming` delivers a long mutating operation's output line by line and
/// is cancellable (`update`, `upgrade`, `uninstall`, `cleanup`, `autoremove`).
protocol BrewRunning: Sendable {
    /// Runs `brew <arguments>`, capturing stdout and stderr separately and
    /// returning the termination status once the process exits.
    func runCapturing(_ arguments: [String]) async throws -> BrewResult

    /// Runs `brew <arguments>`, invoking `onLine` for each combined
    /// stdout/stderr line as it arrives, and returns the termination status.
    /// Honors task cancellation by terminating the child process.
    func runStreaming(_ arguments: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32
}
