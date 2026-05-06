// LanguageFileLocatorTests.swift
// Verifies LanguageFileLocator finds .lproj directories under given roots and filters them by active locale (BCP-47 prefix match plus a small legacy-name allowlist).

import XCTest
@testable import VaderCleaner

/// Drives `LanguageFileLocator` over temp directory trees that mimic
/// real macOS `.lproj` layouts (`/Applications/Foo.app/Contents/Resources/<lang>.lproj`)
/// and confirms that active locales are filtered out while non-active ones
/// surface as `ScanRoot` entries tagged `.languageFiles`.
final class LanguageFileLocatorTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `FileManager.enumerator(at:)` returns realpath-canonical URLs
        // (`/private/var/...`) while `temporaryDirectory` returns the
        // unresolved form (`/var/...`). `resolvingSymlinksInPath` doesn't
        // peek through the `/var → /private/var` mount-style symlink, so we
        // call `realpath(3)` directly to get the same form the enumerator
        // emits. Without this, every "lproj path is in result" assertion
        // hits a `/private/var` vs `/var` false negative.
        tempRoot = try canonicalize(TestHelpers.createTempDirectory())
    }

    private func canonicalize(_ url: URL) throws -> URL {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "realpath failed for \(url.path)"]
            )
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    override func tearDown() {
        if let tempRoot {
            TestHelpers.tearDownTempDirectory(tempRoot)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Filtering

    /// Active locales (`en-US`, `en`) must not appear in the output. Other
    /// languages do, with each `.lproj` returned as its own `ScanRoot` so
    /// `FileScanner` can tag every file inside as `.languageFiles`.
    func test_locate_returnsNonActiveLprojDirsOnly() throws {
        let resources = try makeAppResources(named: "Foo.app")
        let en = try makeLproj("en", in: resources)
        let enUS = try makeLproj("en-US", in: resources)
        let nl = try makeLproj("nl", in: resources)
        let de = try makeLproj("de", in: resources)
        try TestHelpers.createDummyFile(named: "Localizable.strings", size: 8, in: en)
        try TestHelpers.createDummyFile(named: "Localizable.strings", size: 8, in: enUS)
        try TestHelpers.createDummyFile(named: "Localizable.strings", size: 8, in: nl)
        try TestHelpers.createDummyFile(named: "Localizable.strings", size: 8, in: de)

        let locator = LanguageFileLocator(
            scanRoots: [tempRoot],
            activeLanguageCodes: ["en"]
        )

        let lprojRoots = locator.locate()
        let lprojPaths = Set(lprojRoots.map(\.url.path))

        XCTAssertFalse(lprojPaths.contains(en.path), "Active language 'en' should be filtered out")
        XCTAssertFalse(lprojPaths.contains(enUS.path), "BCP-47 'en-US' must match prefix 'en' and be filtered")
        XCTAssertTrue(lprojPaths.contains(nl.path))
        XCTAssertTrue(lprojPaths.contains(de.path))
        for root in lprojRoots {
            XCTAssertEqual(root.category, .languageFiles)
        }
    }

    /// Legacy `.lproj` names like `English.lproj` and `Spanish.lproj` predate
    /// ISO codes and still ship in some bundles. The allowlist maps them to
    /// language codes so `English.lproj` is treated as `en` for active-locale
    /// matching.
    func test_locate_legacyLanguageNamesMapToCodes() throws {
        let resources = try makeAppResources(named: "Bar.app")
        let english = try makeLproj("English", in: resources)
        let spanish = try makeLproj("Spanish", in: resources)
        let french = try makeLproj("French", in: resources)
        try TestHelpers.createDummyFile(named: "MainMenu.nib", size: 100, in: english)
        try TestHelpers.createDummyFile(named: "MainMenu.nib", size: 100, in: spanish)
        try TestHelpers.createDummyFile(named: "MainMenu.nib", size: 100, in: french)

        let locator = LanguageFileLocator(
            scanRoots: [tempRoot],
            activeLanguageCodes: ["en"]
        )

        let lprojRoots = locator.locate()
        let lprojPaths = Set(lprojRoots.map(\.url.path))

        XCTAssertFalse(lprojPaths.contains(english.path), "Legacy 'English.lproj' must be treated as active")
        XCTAssertTrue(lprojPaths.contains(spanish.path))
        XCTAssertTrue(lprojPaths.contains(french.path))
    }

    /// Underscore-separated locale names (`zh_CN`, `pt_BR`) appear in some
    /// bundles. Prefix matching must split on either `-` or `_` so an active
    /// `zh` filters them out.
    func test_locate_underscoreSeparatedLocalesPrefixMatch() throws {
        let resources = try makeAppResources(named: "Baz.app")
        let zhCN = try makeLproj("zh_CN", in: resources)
        let zhTW = try makeLproj("zh_TW", in: resources)
        let ptBR = try makeLproj("pt_BR", in: resources)
        try TestHelpers.createDummyFile(named: "x.strings", size: 4, in: zhCN)
        try TestHelpers.createDummyFile(named: "x.strings", size: 4, in: zhTW)
        try TestHelpers.createDummyFile(named: "x.strings", size: 4, in: ptBR)

        let locator = LanguageFileLocator(
            scanRoots: [tempRoot],
            activeLanguageCodes: ["zh"]
        )

        let lprojRoots = locator.locate()
        let lprojPaths = Set(lprojRoots.map(\.url.path))

        XCTAssertFalse(lprojPaths.contains(zhCN.path))
        XCTAssertFalse(lprojPaths.contains(zhTW.path))
        XCTAssertTrue(lprojPaths.contains(ptBR.path))
    }

    /// `.lproj` directories nested inside `.app` packages must still be found
    /// even though `FileScanner` skips package descendants — the locator does
    /// its own walk specifically because `.lproj` lives under `.app/Contents`.
    func test_locate_findsLprojInsideAppBundles() throws {
        let resources = try makeAppResources(named: "Nested.app")
        let nl = try makeLproj("nl", in: resources)
        try TestHelpers.createDummyFile(named: "x", size: 1, in: nl)

        let locator = LanguageFileLocator(
            scanRoots: [tempRoot],
            activeLanguageCodes: ["en"]
        )

        let lprojRoots = locator.locate()

        XCTAssertEqual(lprojRoots.count, 1)
        XCTAssertEqual(lprojRoots.first?.url.path, nl.path)
    }

    // MARK: - Helpers

    /// Builds `<tempRoot>/<appName>/Contents/Resources` so tests can drop
    /// `.lproj` directories where macOS actually puts them.
    private func makeAppResources(named appName: String) throws -> URL {
        let resources = tempRoot
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        return resources
    }

    private func makeLproj(_ language: String, in resources: URL) throws -> URL {
        let lproj = resources.appendingPathComponent("\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        return lproj
    }
}
