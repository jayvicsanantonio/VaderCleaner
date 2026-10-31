// MailReindexerTests.swift
// Verifies MailReindexer locates Mail envelope-index databases, vacuums/reindexes each, and reports clear errors when Full Disk Access is missing, Mail is open, or the database is locked.

import XCTest
@testable import VaderCleanerCore

final class MailReindexerTests: XCTestCase {

    func test_run_vacuumsEveryLocatedIndexAndReturnsResult() async throws {
        let indexes = [
            URL(fileURLWithPath: "/tmp/mail/V1/Envelope Index"),
            URL(fileURLWithPath: "/tmp/mail/V2/Envelope Index")
        ]
        let vacuumed = TestBox<[URL]>([])
        let runner = MailReindexer(
            locateIndexes: { indexes },
            vacuumIndex: { vacuumed.value.append($0) },
            isMailRunning: { false }
        )

        let output = try await runner.run()

        XCTAssertEqual(vacuumed.value, indexes)
        XCTAssertFalse(output.isEmpty)
    }

    /// Having no Mail data is a finished job rather than a failure: throwing
    /// here would keep the task due forever for anyone who doesn't use Mail.
    func test_run_reportsNothingToDoWhenFolderReadableButEmpty() async throws {
        let runner = MailReindexer(
            locateIndexes: { [] },
            vacuumIndex: { _ in XCTFail("Nothing to vacuum") },
            isMailRunning: { false }
        )

        let output = try await runner.run()

        XCTAssertFalse(output.isEmpty)
    }

    /// Vacuuming a database another process has open is what the lock error
    /// used to catch, so it is refused before `sqlite3` is ever started.
    func test_run_refusesWhileMailIsRunning() async {
        let runner = MailReindexer(
            locateIndexes: { [URL(fileURLWithPath: "/tmp/mail/Envelope Index")] },
            vacuumIndex: { _ in XCTFail("Must not touch the database while Mail is open") },
            isMailRunning: { true }
        )
        do {
            _ = try await runner.run()
            XCTFail("Expected run() to throw while Mail is open")
        } catch MailReindexerError.mailIsRunning {
            // Expected.
        } catch {
            XCTFail("Expected .mailIsRunning, got \(error)")
        }
    }

    func test_run_surfacesFullDiskAccessRequiredFromLocator() async {
        // The locator signals a permission failure (app not in Full Disk
        // Access); run() must propagate it rather than report "no mail".
        let runner = MailReindexer(
            locateIndexes: { throw MailReindexerError.fullDiskAccessRequired },
            vacuumIndex: { _ in },
            isMailRunning: { false }
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
            vacuumIndex: { _ in throw Locked() },
            isMailRunning: { false }
        )
        do {
            _ = try await runner.run()
            XCTFail("Expected run() to throw when the vacuum fails")
        } catch {
            // Expected.
        }
    }
}
