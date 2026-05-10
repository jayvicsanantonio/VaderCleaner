// BrowserDetector.swift
// Reports which browsers are installed on the machine by checking known .app bundle locations under /Applications and ~/Applications.

import Foundation

/// Test seam for "which browsers does this Mac have?". The default
/// implementation walks `/Applications` and `~/Applications`; tests inject
/// a closure-driven `existsAt:` predicate so they can stage any combination
/// without touching real disk state.
protocol BrowserDetecting {
    func installedBrowsers() -> [Browser]
}

/// Production detector. Always includes Safari (ships with macOS and is
/// not uninstallable through normal channels), and includes any other
/// browser whose `.app` exists under `/Applications` or
/// `~/Applications`.
struct DefaultBrowserDetector: BrowserDetecting {

    private let homeDirectory: URL
    private let existsAt: (URL) -> Bool

    /// - Parameter existsAt: closure that answers "does a file/directory
    ///   exist at this URL?". Defaults to `FileManager.fileExists`. The
    ///   indirection makes detection trivially testable without faking out
    ///   `/Applications` on the host.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        existsAt: @escaping (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.existsAt = existsAt
    }

    func installedBrowsers() -> [Browser] {
        let userApplications = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)

        return Browser.allCases.filter { browser in
            // Safari is treated as always installed — see type doc.
            if browser == .safari { return true }
            let candidates = [
                systemApplications.appendingPathComponent(browser.appBundleName),
                userApplications.appendingPathComponent(browser.appBundleName)
            ]
            return candidates.contains(where: existsAt)
        }
    }
}
