// MailReindexerTests.swift
// Verifies MailReindexer locates Mail envelope-index databases, vacuums/reindexes each, and reports clear errors when Mail data is absent or the database is locked.

import XCTest
@testable import VaderCleaner

final class MailReindexerTests: XCTestCase {

    func test_run_vacuumsEveryLocatedIndexAndReturnsResult() async throws {
        let indexes = [
            URL(fileURLWithPath: "/tmp/mail/V1/Envelope Index"),
            URL(fileURLWithPath: "/tmp/mail/V2/Envelope Index")
        ]
        var vacuumed: [URL] = []
        let runner = MailReindexer(
            locateIndexes: { indexes },
            vacuumIndex: { vacuumed.append($0) }
        )

        let output = try await runner.run()

        XCTAssertEqual(vacuumed, indexes)
        XCTAssertFalse(output.isEmpty)
    }

    func test_run_throwsNoMailDataWhenFolderReadableButEmpty() async {
        let runner = MailReindexer(locateIndexes: { [] }, vacuumIndex: { _ in })
        do {
            _ = try await runner.run()
            XCTFail("Expected run() to throw when no Mail data is present")
        } catch MailReindexerError.noMailData {
            // Expected — readable but nothing to reindex.
        } catch {
            XCTFail("Expected .noMailData, got \(error)")
        }
    }

    func test_run_surfacesFullDiskAccessRequiredFromLocator() async {
        // The locator signals a permission failure (app not in Full Disk
        // Access); run() must propagate it rather than report "no mail".
        let runner = MailReindexer(
            locateIndexes: { throw MailReindexerError.fullDiskAccessRequired },
            vacuumIndex: { _ in }
        )
        do {
            _ = try await runner.run()
            XCTFail("Expected run() to throw .fullDiskAccessRequired")
        } catch MailReindexerError.fullDiskAccessRequired {
            // Expected.
        } catch {
            XCTFail("Expected .fullDiskAccessRequired, got \(error)")
        }
    }

    func test_run_throwsWhenVacuumFails() async {
        struct Locked: Error {}
        let runner = MailReindexer(
            locateIndexes: { [URL(fileURLWithPath: "/tmp/mail/Envelope Index")] },
            vacuumIndex: { _ in throw Locked() }
        )
        do {
            _ = try await runner.run()
            XCTFail("Expected run() to throw when the vacuum fails")
        } catch {
            // Expected.
        }
    }
}
