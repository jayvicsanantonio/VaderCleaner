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
        let (data, _) = try await httpFetcher.data(from: feedURL)
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
            let lhsVer = lhs.shortVersion
            let rhsVer = rhs.shortVersion
            return VersionComparator.compare(lhsVer, rhsVer) == .orderedAscending
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
            currentShortVersion = nil
            currentVersion = nil
            return
        }
        if inItem, local == "enclosure" {
            // Pull shortVersionString / version from the enclosure
            // attributes — that's where Sparkle places them in most feeds.
            // Some older feeds put `sparkle:shortVersionString` on the
            // `<item>` itself, but the enclosure variant is dominant.
            if let urlString = attributeDict["url"], let url = URL(string: urlString) {
                currentEnclosureURL = url
            }
            if currentShortVersion == nil {
                currentShortVersion = attributeDict["sparkle:shortVersionString"]
                    ?? attributeDict["shortVersionString"]
            }
            if currentVersion == nil {
                currentVersion = attributeDict["sparkle:version"]
                    ?? attributeDict["version"]
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
