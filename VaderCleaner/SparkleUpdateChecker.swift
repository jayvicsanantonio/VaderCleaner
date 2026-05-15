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
    private let log = Logger(subsystem: "com.personal.VaderCleaner",
                             category: "SparkleUpdateChecker")

    init(httpFetcher: HTTPFetching = URLSession.shared) {
        self.httpFetcher = httpFetcher
    }

    func feedURL(for app: AppInfo) -> URL? {
        // `Bundle(url:)` + `object(forInfoDictionaryKey:)` transparently
        // handles binary vs. XML plists and leverages the system bundle
        // cache, rather than us re-reading and re-parsing Info.plist by
        // hand.
        guard let bundle = Bundle(url: app.bundleURL),
              let raw = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
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
    /// downloadable `<enclosure>` **and** whose
    /// `sparkle:minimumSystemVersion` (if any) the running macOS
    /// satisfies. Items without an enclosure are skipped — release-notes-
    /// only entries aren't actionable updates — and items that require a
    /// newer macOS than the user is on are filtered out so we never offer
    /// a download Sparkle itself would refuse to install.
    ///
    /// - Parameter currentSystemVersion: the running macOS product
    ///   version ("14.5.0"). Defaults to the live value; injected by
    ///   tests so the OS-compatibility filter is deterministic.
    static func parseAppcast(
        xml: Data,
        currentSystemVersion: String = DefaultSparkleUpdateChecker.currentSystemVersionString()
    ) -> SparkleAppcastItem? {
        let parser = AppcastXMLParser()
        let xmlParser = XMLParser(data: xml)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { return nil }
        return parser.bestItem(currentSystemVersion: currentSystemVersion)
    }

    /// The running macOS product version as a dotted string. Kept here
    /// (rather than read inline) so the OS-compatibility filter has a
    /// single, injectable source of truth.
    static func currentSystemVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// Streaming `XMLParser` delegate that collects `<item>` entries from an
/// appcast and picks the newest enclosure-bearing one.
private final class AppcastXMLParser: NSObject, XMLParserDelegate {

    /// Each parsed item paired with its `sparkle:minimumSystemVersion`
    /// (nil when the feed doesn't constrain the OS for that item).
    private var collected: [(item: SparkleAppcastItem, minimumSystemVersion: String?)] = []
    private var currentEnclosureURL: URL?
    private var currentShortVersion: String?
    private var currentVersion: String?
    private var currentMinimumSystemVersion: String?
    private var inItem = false
    /// True while inside a `<sparkle:deltas>` block. Delta enclosures are
    /// binary patches keyed to a specific installed build and are useless
    /// as a user-facing download, so we ignore everything nested there.
    private var inDeltas = false
    /// Local name of the element whose text we're currently accumulating
    /// (`minimumSystemVersion`, `shortVersionString`, or `version`), or
    /// nil when not inside one of those.
    private var bufferingElement: String?
    private var textBuffer = ""

    func bestItem(currentSystemVersion: String) -> SparkleAppcastItem? {
        let compatible = collected.filter { entry in
            guard let minimum = entry.minimumSystemVersion, !minimum.isEmpty else {
                return true
            }
            // Keep the item only when the running OS is at least the
            // required minimum (current >= minimum).
            return VersionComparator.compare(currentSystemVersion, minimum) != .orderedAscending
        }
        return compatible.map(\.item).max { lhs, rhs in
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
            inDeltas = false
            currentEnclosureURL = nil
            currentMinimumSystemVersion = nil
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
        guard inItem else { return }
        if local == "deltas" {
            inDeltas = true
            return
        }
        if !inDeltas,
           local == "minimumSystemVersion"
            || local == "shortVersionString"
            || local == "version" {
            // These can appear as child elements carrying their value as
            // text (Sparkle's element form) rather than as enclosure
            // attributes — buffer the character data until the end tag.
            bufferingElement = local
            textBuffer = ""
            return
        }
        if local == "enclosure" {
            // Skip delta enclosures: those nested in `<sparkle:deltas>`
            // and any carrying `sparkle:deltaFrom`. They're patches Sparkle
            // applies to one specific installed build — opening one as a
            // manual download gives the user a broken link.
            if inDeltas
                || attributeDict["sparkle:deltaFrom"] != nil
                || attributeDict["deltaFrom"] != nil {
                return
            }
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
        if local == "deltas" {
            inDeltas = false
            return
        }
        if let buffering = bufferingElement, local == buffering {
            let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? nil : trimmed
            switch buffering {
            case "minimumSystemVersion":
                currentMinimumSystemVersion = value
            case "shortVersionString":
                // Element form is the lowest-precedence source — only use
                // it when neither an item nor enclosure attribute set it.
                if currentShortVersion == nil { currentShortVersion = value }
            case "version":
                if currentVersion == nil { currentVersion = value }
            default:
                break
            }
            bufferingElement = nil
            textBuffer = ""
            return
        }
        guard local == "item", inItem else {
            return
        }
        inItem = false
        inDeltas = false
        // Only emit items that actually point at something the user can
        // download — a release-notes-only item isn't an update.
        guard let downloadURL = currentEnclosureURL else { return }
        let shortVersion = currentShortVersion ?? currentVersion ?? ""
        guard !shortVersion.isEmpty else { return }
        collected.append((
            item: SparkleAppcastItem(
                shortVersion: shortVersion,
                version: currentVersion,
                downloadURL: downloadURL
            ),
            minimumSystemVersion: currentMinimumSystemVersion
        ))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Only accumulate while inside one of the buffered version
        // elements — we don't care about any other text nodes.
        if bufferingElement != nil {
            textBuffer.append(string)
        }
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
