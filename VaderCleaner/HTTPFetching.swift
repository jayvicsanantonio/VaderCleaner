// HTTPFetching.swift
// Minimal HTTP fetch seam used by the App Updater so the Sparkle and App Store checkers can be unit-tested without hitting the real network.

import Foundation

/// Tiny protocol shaped like the part of `URLSession` we actually use. The
/// production conformance is `URLSession`; unit tests inject a stub that
/// returns fixture bytes.
///
/// `Sendable` so the App Updater view-model can hand the fetcher into a
/// `TaskGroup` and have it called concurrently from multiple tasks.
protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPFetching {}
