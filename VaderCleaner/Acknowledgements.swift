// Acknowledgements.swift
// Loads the open-source license text staged into the app bundle so Settings can surface the terms VaderCleaner ships under.

import Foundation

/// Reads the bundled third-party license text.
///
/// `Scripts/stage-clamav.sh` rsyncs `Vendor/clamav/LICENSES/` into the app at
/// `<Resources>/clamav/LICENSES/`. ClamAV is GPL-2.0, so showing these terms —
/// and the accompanying written offer of source in `README.txt` — is part of
/// shipping the binary, not decoration.
///
/// Every file in the directory is included rather than a hardcoded list, so
/// bundling another dependency surfaces its license automatically instead of
/// silently omitting it. `resourcesURL` is injected so tests can stage a
/// directory of their own.
enum Acknowledgements {

    /// Filename shown first: it introduces the components and says where to get
    /// their sources, which frames the license text that follows.
    private static let preambleName = "README.txt"

    /// The concatenated license text, or `nil` when nothing is staged — a
    /// development build without the vendored ClamAV, for instance.
    static func load(resourcesURL: URL? = Bundle.main.resourceURL) -> String? {
        guard let resourcesURL else { return nil }
        let directory = resourcesURL.appendingPathComponent("clamav/LICENSES", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }

        // The preamble leads; everything else follows in a stable alphabetical
        // order so the screen doesn't reshuffle between launches.
        let ordered = names.filter { $0 != preambleName }.sorted()
        let sections = ([preambleName] + ordered).compactMap { name -> String? in
            let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }
}
