// BrewOutputParser.swift
// Pure parsing of Homebrew command output (list, leaves, uses, outdated JSON, cleanup dry-run, autoremove) into the Homebrew Manager's value types.

import Foundation

/// Stateless parsers turning raw `brew` stdout into typed values. Kept free of
/// any process or I/O so every payload shape — including malformed and
/// edge-case output — is covered by fixture tests.
enum BrewOutputParser {

    // MARK: - list / leaves / uses

    /// Parses `brew list --formula --versions` (or `--cask --versions`) output.
    /// Each non-empty line is `name version [version …]`; a line with only a
    /// name (no version) still yields a package with an empty version list.
    static func parseListVersions(_ stdout: String, kind: BrewPackageKind, leaves: Set<String> = []) -> [BrewPackage] {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> BrewPackage? in
                let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let name = fields.first else { return nil }
                let versions = Array(fields.dropFirst())
                // Casks have no dependency graph in the `leaves` sense, so they
                // are always treated as leaves; a formula is a leaf only when
                // `brew leaves` names it.
                let isLeaf = kind == .cask || leaves.contains(name)
                return BrewPackage(
                    name: name,
                    kind: kind,
                    installedVersions: versions,
                    isLeaf: isLeaf
                )
            }
    }

    /// Parses `brew leaves --installed-on-request` — one formula name per line.
    static func parseLeaves(_ stdout: String) -> Set<String> {
        Set(
            stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    /// Parses `brew uses --installed <name>` — one dependent package name per
    /// line. An empty result means nothing installed depends on the queried
    /// package (safe to remove).
    static func parseUses(_ stdout: String) -> [String] {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - outdated --json=v2

    /// Decodes `brew outdated --json=v2` into outdated items. The v2 schema
    /// carries `formulae` and `casks` arrays; casks have no `pinned` field so
    /// it defaults to `false`. Throws on malformed JSON so the view model can
    /// surface a parse failure rather than silently reporting nothing.
    static func parseOutdatedJSON(_ data: Data) throws -> [BrewOutdatedItem] {
        let payload = try JSONDecoder().decode(OutdatedPayload.self, from: data)
        let formulae = payload.formulae.map { $0.item(kind: .formula) }
        let casks = payload.casks.map { $0.item(kind: .cask) }
        return formulae + casks
    }

    private struct OutdatedPayload: Decodable {
        var formulae: [OutdatedEntry] = []
        var casks: [OutdatedEntry] = []
    }

    private struct OutdatedEntry: Decodable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String
        let pinned: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
            case pinned
        }

        func item(kind: BrewPackageKind) -> BrewOutdatedItem {
            BrewOutdatedItem(
                name: name,
                kind: kind,
                installedVersion: installedVersions.last ?? "",
                candidateVersion: currentVersion,
                isPinned: pinned ?? false
            )
        }
    }

    // MARK: - cleanup -n / autoremove

    /// Parses the reclaimable total from `brew cleanup -n` output, e.g.
    /// "This operation would free approximately 2.5GB of disk space." Returns
    /// `nil` (not zero) when no total is present so the caller can show the
    /// amount as unavailable rather than a fabricated number.
    static func parseCleanupDryRun(_ stdout: String) -> Int64? {
        for line in stdout.split(separator: "\n") {
            guard line.contains("would free") else { continue }
            if let bytes = firstByteSize(in: String(line)) {
                return bytes
            }
        }
        return nil
    }

    /// Parses the formula names removed by `brew autoremove`. Names appear
    /// between the "Autoremoving N unneeded formulae:" header and the next
    /// `==>` section marker.
    static func parseAutoremove(_ stdout: String) -> [String] {
        var names: [String] = []
        var collecting = false
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                // A header like "==> Autoremoving 2 unneeded formulae:" starts a
                // block of names; any other "==>" marker ends it.
                collecting = line.contains("Autoremoving")
                continue
            }
            if collecting, !line.isEmpty {
                names.append(line)
            }
        }
        return names
    }

    // MARK: - Byte-size parsing

    private static let byteUnits: [(suffix: String, multiplier: Double)] = [
        // Longest suffixes first so "KB" isn't matched as "B".
        ("TB", 1_099_511_627_776),
        ("GB", 1_073_741_824),
        ("MB", 1_048_576),
        ("KB", 1_024),
        ("B", 1),
    ]

    /// Finds the first "<number><unit>" disk-size token in a line (e.g.
    /// "2.5GB", "512MB", "900B") and returns it in bytes.
    static func firstByteSize(in line: String) -> Int64? {
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = CharacterSet.whitespaces
        while !scanner.isAtEnd {
            let startIndex = scanner.currentIndex
            if let value = scanner.scanDouble() {
                // A number was found — check whether a size unit immediately
                // follows it (allowing no intervening space).
                for unit in byteUnits where scanner.scanString(unit.suffix) != nil {
                    return Int64((value * unit.multiplier).rounded())
                }
                // Number wasn't a size; keep scanning from just past it.
                if scanner.currentIndex == startIndex {
                    scanner.currentIndex = line.index(after: startIndex)
                }
            } else {
                scanner.currentIndex = line.index(after: scanner.currentIndex)
            }
        }
        return nil
    }
}
