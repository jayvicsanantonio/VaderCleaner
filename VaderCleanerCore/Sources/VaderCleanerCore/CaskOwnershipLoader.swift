// CaskOwnershipLoader.swift
// Builds the cask ownership map by reading `brew info --json=v2 --installed` and cross-checking the Caskroom, degrading to an empty map whenever Homebrew is absent or its inventory can't be trusted.

import Foundation
import os.log

/// Loads which installed apps Homebrew owns.
///
/// Every failure path yields an **empty** map rather than a partial one.
/// An empty map claims nothing, so the Updater falls back to the
/// behaviour it had before ownership existed — offering downloads. A
/// partial map would be worse than none: it would silently suppress real
/// updates for apps it happened not to describe.
struct CaskOwnershipLoader: Sendable {

    typealias MakeRunner = @Sendable (URL) -> BrewRunning

    private let locator: BrewLocating
    private let makeRunner: MakeRunner
    /// `.default` is documented thread-safe; the Caskroom listing is a
    /// single read and the fixtures tests inject are single-threaded.
    nonisolated(unsafe) private let fileManager: FileManager
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "CaskOwnershipLoader")

    init(
        locator: BrewLocating = DefaultBrewLocator(),
        makeRunner: @escaping MakeRunner = { url in DefaultBrewRunner(brewURL: url) },
        fileManager: FileManager = .default
    ) {
        self.locator = locator
        self.makeRunner = makeRunner
        self.fileManager = fileManager
    }

    func load() async -> CaskOwnershipMap {
        guard let brewURL = locator.locate() else { return CaskOwnershipMap() }
        do {
            let result = try await makeRunner(brewURL)
                .runCapturing(["info", "--json=v2", "--installed"])
            guard result.terminationStatus == 0 else {
                // Only the exit code is public: brew's stderr can name
                // user paths.
                log.error("brew info failed (status \(result.terminationStatus, privacy: .public))")
                return CaskOwnershipMap()
            }
            let casks = try BrewOutputParser.parseInstalledCasks(Data(result.standardOutput.utf8))
            return CaskOwnershipMap(
                casks: casks,
                caskroomTokens: caskroomTokens(brewURL: brewURL)
            )
        } catch {
            log.error("Cask ownership load failed: \(String(describing: error), privacy: .private)")
            return CaskOwnershipMap()
        }
    }

    /// Token directory names under `<prefix>/Caskroom`.
    ///
    /// The prefix is derived from the binary path (`<prefix>/bin/brew`)
    /// rather than by running `brew --prefix`, which would cost a second
    /// subprocess to learn something the located path already states.
    private func caskroomTokens(brewURL: URL) -> Set<String> {
        let caskroom = brewURL
            .deletingLastPathComponent()   // …/bin
            .deletingLastPathComponent()   // …/<prefix>
            .appendingPathComponent("Caskroom", isDirectory: true)
        // An absent Caskroom is not an error — there is simply nothing to
        // cross-check, which is also true on a formula-only install.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: caskroom,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(entries.compactMap { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            return isDirectory == true ? entry.lastPathComponent : nil
        })
    }
}
