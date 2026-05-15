// SparkleUpdateChecker.swift
// Sparkle appcast pipeline — reads SUFeedURL from an .app bundle, fetches the appcast XML, and parses out the newest <item> with a downloadable enclosure.

import Foundation
import os.log

/// Single appcast `<item>` reduced to the fields the App Updater consumes.
/// `shortVersion` is the user-facing version string ("2.0.0"); `version`
/// is the build number Sparkle uses for ordering ("2000"). The view-model
/// presents `shortVersion` and stores `downloadURL` for the "Update"
/// action.
struct SparkleAppcastItem: Hashable, Sendable {
    let shortVersion: String
    let version: String?
    let downloadURL: URL
}

/// Test seam between the App Updater and a live Sparkle feed. Production
/// implementation reads `SUFeedURL` from the bundle and fetches the
/// appcast over HTTPS; tests inject a stub that returns fixture bytes.
protocol SparkleUpdateChecking: Sendable {
    /// Returns the appcast URL for an app, or `nil` when the bundle's
    /// `Info.plist` doesn't carry `SUFeedURL` (i.e. not a Sparkle app).
    func feedURL(for app: AppInfo) -> URL?

    /// Fetches and parses the appcast at `feedURL`, returning the newest
    /// `<item>` with a downloadable enclosure, or `nil` if the feed has
    /// no usable items.
    func fetchAppcast(feedURL: URL) async throws -> SparkleAppcastItem?
}

/// Production implementation. The Info.plist read happens synchronously
/// — it's a single small file — but the appcast fetch is async because
/// it crosses the network.
struct DefaultSparkleUpdateChecker: SparkleUpdateChecking, Sendable {

    private let httpFetcher: HTTPFetching
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "SparkleUpdateChecker")

    init(httpFetcher: HTTPFetching = URLSession.shared,
         fileManager: FileManager = .default) {
        self.httpFetcher = httpFetcher
        self.fileManager = fileManager
    }

    func feedURL(for app: AppInfo) -> URL? {
        let infoPlist = app.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let raw = plist["SUFeedURL"] as? String,
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    func fetchAppcast(feedURL: URL) async throws -> SparkleAppcastItem? {
        let (data, response) = try await httpFetcher.data(from: feedURL)
        // Only parse a successful response — a 404/5xx body is usually an
        // HTML error page that would either parse to nothing or, worse,
        // yield a bogus item. Treat it as "no appcast available".
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return Self.parseAppcast(xml: data)
    }

    /// Parses appcast XML and returns the newest `<item>` (by
    /// `shortVersionString`, with `version` as a tiebreaker) that has a
    /// downloadable `<enclosure>`. Items without an enclosure are
    /// skipped — release-notes-only entries aren't actionable updates.
    static func parseAppcast(xml: Data) -> SparkleAppcastItem? {
        let parser = AppcastXMLParser()
        let xmlParser = XMLParser(data: xml)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { return nil }
        return parser.bestItem()
    }
}

/// Streaming `XMLParser` delegate that collects `<item>` entries from an
/// appcast and picks the newest enclosure-bearing one.
private final class AppcastXMLParser: NSObject, XMLParserDelegate {

    private var items: [SparkleAppcastItem] = []
    private var currentEnclosureURL: URL?
    private var currentShortVersion: String?
    private var currentVersion: String?
    private var inItem = false

    func bestItem() -> SparkleAppcastItem? {
        return items.max { lhs, rhs in
            let shortComparison = VersionComparator.compare(
                lhs.shortVersion,
                rhs.shortVersion
            )
            // When two items advertise the same marketing version, fall
            // back to the build (`sparkle:version`) so a same-short-string
            // hotfix isn't passed over for an older artifact.
            if shortComparison == .orderedSame {
                return VersionComparator.compare(
                    lhs.version ?? "0",
                    rhs.version ?? "0"
                ) == .orderedAscending
            }
            return shortComparison == .orderedAscending
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(for: elementName)
        if local == "item" {
            inItem = true
            currentEnclosureURL = nil
            // Seed from any version attributes carried on the `<item>`
            // itself — older feeds place `sparkle:shortVersionString` /
            // `sparkle:version` here rather than on the enclosure. The
            // enclosure handler below still overrides these when the
            // (dominant) enclosure-attribute form is present.
            currentShortVersion = attributeDict["sparkle:shortVersionString"]
                ?? attributeDict["shortVersionString"]
            currentVersion = attributeDict["sparkle:version"]
                ?? attributeDict["version"]
            return
        }
        if inItem, local == "enclosure" {
            // The enclosure attributes are where Sparkle places the
            // version in most modern feeds; prefer them over any
            // item-level seed but keep the seed as a fallback.
            if let urlString = attributeDict["url"], let url = URL(string: urlString) {
                currentEnclosureURL = url
            }
            if let short = attributeDict["sparkle:shortVersionString"]
                ?? attributeDict["shortVersionString"] {
                currentShortVersion = short
            }
            if let version = attributeDict["sparkle:version"]
                ?? attributeDict["version"] {
                currentVersion = version
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(for: elementName)
        guard local == "item", inItem else {
            return
        }
        inItem = false
        // Only emit items that actually point at something the user can
        // download — a release-notes-only item isn't an update.
        guard let downloadURL = currentEnclosureURL else { return }
        let shortVersion = currentShortVersion ?? currentVersion ?? ""
        guard !shortVersion.isEmpty else { return }
        items.append(SparkleAppcastItem(
            shortVersion: shortVersion,
            version: currentVersion,
            downloadURL: downloadURL
        ))
    }

    /// XMLParser delivers the qualified name ("sparkle:enclosure") rather
    /// than the local name ("enclosure") when namespace processing is off.
    /// Strip the prefix here so the dispatcher above stays simple.
    private func localName(for elementName: String) -> String {
        if let colonIndex = elementName.firstIndex(of: ":") {
            return String(elementName[elementName.index(after: colonIndex)...])
        }
        return elementName
    }
}
