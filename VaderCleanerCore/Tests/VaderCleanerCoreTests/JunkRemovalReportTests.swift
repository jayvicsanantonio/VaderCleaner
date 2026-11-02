// JunkRemovalReportTests.swift
// Pins what a junk clean reports back — bytes freed versus moved to the Trash, what failed, what was stopped — and that the Trash and the helper's refusals come out the way the screen tells the user they did.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite("Junk removal report")
struct JunkRemovalReportTests {

    private func file(_ path: String, _ size: Int64, _ category: ScanCategory) -> ScannedFile {
        ScannedFile(url: URL(fileURLWithPath: path), size: size, lastAccessDate: nil, lastModifiedDate: nil, category: category)
    }

    private func touch(_ url: URL, bytes: Int = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    @Test("Files sent to the Trash count as moved, not freed")
    func trashedFilesAreNotFreed() async {
        let deleter = SystemJunkDeleter(helperProvider: { _ in nil }, trashItem: { _ in })

        let report = await deleter.remove([file("/Users/me/Library/Caches/a", 100, .userCache)])

        #expect(report.bytesFreed == 0)
        #expect(report.bytesMovedToTrash == 100)
        #expect(report.failedCount == 0)
    }

    @Test("Items removed by the helper count as freed")
    func helperRemovalsAreFreed() async {
        let spy = HelperProtocolSpy()
        let deleter = SystemJunkDeleter(helperProvider: { _ in spy }, trashItem: { _ in })

        let report = await deleter.remove([file("/Library/Caches/a", 100, .systemCache)])

        #expect(report.bytesFreed == 100)
        #expect(report.bytesMovedToTrash == 0)
    }

    @Test("One path the helper refuses doesn't cost the batch the paths it removed")
    func partialHelperFailureKeepsCredit() async {
        let spy = HelperProtocolSpy(defaultReply: .failure(HelperDeletionValidationError.disallowedPath("x")))
        // Both paths exist before the call; only one is gone after it.
        let lookups = TestBox<[String: Int]>([:])
        let deleter = SystemJunkDeleter(
            helperProvider: { _ in spy },
            trashItem: { _ in },
            pathIsGone: { path in
                let lookup = lookups.withLock { counts -> Int in
                    counts[path, default: 0] += 1
                    return counts[path, default: 0]
                }
                return lookup > 1 && path.hasSuffix("/gone")
            }
        )

        let report = await deleter.remove([
            file("/Library/Caches/gone", 1_000, .systemCache),
            file("/Library/Caches/still-here", 7, .systemCache),
        ])

        #expect(report.bytesFreed == 1_000)
        #expect(report.failedCount == 1)
    }

    @Test("A path already gone before a failed batch is neither credited nor a failure")
    func alreadyGoneBeforeTheBatchEarnsNothing() async {
        let spy = HelperProtocolSpy(defaultReply: .failure(HelperDeletionValidationError.disallowedPath("x")))
        let deleter = SystemJunkDeleter(helperProvider: { _ in spy }, trashItem: { _ in }, pathIsGone: { _ in true })

        let report = await deleter.remove([file("/Library/Caches/stale", 1_000, .systemCache)])

        #expect(report.bytesFreed == 0)
        #expect(report.failedCount == 0)
        #expect(report.removedCount == 0)
    }

    @Test("Paths a timed-out batch hasn't removed yet are unconfirmed, not failed")
    func timedOutBatchIsUnconfirmed() async {
        let spy = HelperProtocolSpy(defaultReply: .drop)
        let lookups = TestBox<[String: Int]>([:])
        let deleter = SystemJunkDeleter(
            helperProvider: { errorHandler in
                errorHandler(HelperConnectionError.timedOut)
                return spy
            },
            trashItem: { _ in },
            pathIsGone: { path in
                let lookup = lookups.withLock { counts -> Int in
                    counts[path, default: 0] += 1
                    return counts[path, default: 0]
                }
                return lookup > 1 && path.hasSuffix("/gone")
            }
        )

        let report = await deleter.remove([
            file("/Library/Caches/gone", 1_000, .systemCache),
            file("/Library/Caches/pending", 7, .systemCache),
        ])

        #expect(report.bytesFreed == 1_000)
        #expect(report.failedCount == 0)
        #expect(report.unconfirmedCount == 1)
        #expect(!report.finishedCleanly)
        #expect(report.details.contains { $0.contains("1 item") })
    }

    @Test("A batch that timed out with nothing confirmed gone counts as removing nothing")
    func timedOutWithNothingRemoved() async {
        let spy = HelperProtocolSpy(defaultReply: .drop)
        let deleter = SystemJunkDeleter(
            helperProvider: { errorHandler in
                errorHandler(HelperConnectionError.timedOut)
                return spy
            },
            trashItem: { _ in },
            pathIsGone: { _ in false }
        )

        let report = await deleter.remove([file("/Library/Caches/a", 1, .systemCache)])

        #expect(report.removedNothing)
    }

    @Test("Helper batches stay small enough for Stop to take effect soon")
    func helperBatchesAreBounded() {
        #expect(SystemJunkDeleter.defaultHelperBatchSize <= 1_000)
    }

    @Test("An unreachable helper removed nothing")
    func unreachableHelperCreditsNothing() async {
        let deleter = SystemJunkDeleter(helperProvider: { _ in nil }, trashItem: { _ in }, pathIsGone: { _ in false })

        let report = await deleter.remove([file("/Library/Caches/a", 1_000, .systemCache)])

        #expect(report.totalBytes == 0)
        #expect(report.failedCount == 1)
        #expect(report.removedNothing)
    }

    @Test("delete throws when nothing could be removed, so a clean can't read as a success")
    func deleteThrowsWhenNothingRemoved() async {
        let deleter = SystemJunkDeleter(helperProvider: { _ in nil }, trashItem: { _ in }, pathIsGone: { _ in false })

        await #expect(throws: JunkRemovalError.self) {
            _ = try await deleter.delete([file("/Library/Caches/a", 1_000, .systemCache)])
        }
    }

    @Test("A file a scan listed that has since gone is neither credited nor a failure")
    func alreadyGoneIsNotAFailure() async {
        let deleter = SystemJunkDeleter(helperProvider: { _ in nil }, trashItem: { _ in
            throw CocoaError(.fileNoSuchFile)
        })

        let report = await deleter.remove([file("/Users/me/Library/Caches/a", 100, .userCache)])

        #expect(report.totalBytes == 0)
        #expect(report.failedCount == 0)
        #expect(!report.removedNothing)
    }

    @Test("A locked file counts as a failure and the rest still go")
    func lockedFileFailsAlone() async {
        let deleter = SystemJunkDeleter(helperProvider: { _ in nil }, trashItem: { url in
            if url.lastPathComponent == "locked" { throw CocoaError(.fileWriteNoPermission) }
        })

        let report = await deleter.remove([
            file("/Users/me/Library/Logs/locked", 5, .userLogs),
            file("/Users/me/Library/Logs/ok", 9, .userLogs),
        ])

        #expect(report.bytesMovedToTrash == 9)
        #expect(report.failedCount == 1)
    }

    @Test("Cleaning the Trash leaves nothing behind")
    func trashCleanLeavesItEmpty() async throws {
        // Under /private/tmp rather than the usual temp directory: the walk resolves
        // that one to /private/var/…, which the deleter routes to the helper.
        let home = URL(fileURLWithPath: "/private/tmp/VaderCleanerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try touch(trash.appendingPathComponent("Project/src/main.swift"))
        try FileManager.default.createDirectory(at: trash.appendingPathComponent("EmptyFolder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("alias-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )
        try touch(trash.appendingPathComponent("loose.dmg"))

        let files = try await FileScanner().scan(
            roots: [ScanRoot(url: trash, category: .trash, packagesAsFiles: true, rollsUpTopLevelItems: true)],
            excluding: []
        )
        let deleter = SystemJunkDeleter(homeDirectory: home, helperProvider: { _ in nil }, trashItem: { _ in
            Issue.record("Items already in the Trash are removed, not moved to it")
        })
        let report = await deleter.remove(files)

        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        #expect(report.failedCount == 0)
        #expect(report.bytesFreed == 20)
    }

    @Test("Progress reaches the full count, across both kinds of removal")
    func progressReachesTheTotal() async {
        let spy = HelperProtocolSpy()
        let seen = TestBox<[Int]>([])
        let deleter = SystemJunkDeleter(helperProvider: { _ in spy }, trashItem: { _ in }, helperBatchSize: 2)

        _ = await deleter.remove(
            [
                file("/Users/me/Library/Caches/a", 1, .userCache),
                file("/Library/Caches/b", 1, .systemCache),
                file("/Library/Caches/c", 1, .systemCache),
                file("/Library/Caches/d", 1, .systemCache),
            ],
            onProgress: { count in seen.withLock { $0.append(count) } }
        )

        #expect(seen.value.last == 4)
        #expect(seen.value == seen.value.sorted())
    }

    @Test("A cancelled clean stops between items and says so")
    func cancellationStopsBetweenItems() async {
        let deleter = SystemJunkDeleter(helperProvider: { _ in nil }, trashItem: { _ in })
        let files = (0..<3).map { file("/Users/me/Library/Caches/\($0)", 1, .userCache) }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await deleter.remove(files)
        }
        let report = await task.value

        #expect(report.wasCancelled)
        #expect(report.bytesMovedToTrash == 0)
    }

    // MARK: - Result copy

    @Test("The headline never calls Trash bytes freed")
    func headlineCopy() {
        #expect(JunkRemovalReport(bytesFreed: 2_000_000, removedCount: 1).headline.contains("freed"))
        let trashed = JunkRemovalReport(bytesMovedToTrash: 2_000_000, removedCount: 1)
        #expect(trashed.headline.contains("Trash"))
        #expect(!trashed.headline.contains("freed"))
        #expect(JunkRemovalReport().headline == "Nothing was removed")
    }

    @Test("Removing only zero-byte items still reads as a removal")
    func headlineForZeroByteRemovals() {
        #expect(JunkRemovalReport(removedCount: 1).headline == "1 item removed")
        #expect(JunkRemovalReport(removedCount: 3).headline == "3 items removed")
    }

    @Test("Details name the Trash, the failures, and a stopped clean")
    func detailCopy() {
        let report = JunkRemovalReport(bytesFreed: 1, bytesMovedToTrash: 1_000_000, removedCount: 2, failedCount: 3, wasCancelled: true)
        #expect(report.details.count == 3)
        #expect(report.details[0].contains("Trash"))
        #expect(report.details[1] == "3 items couldn't be removed.")
        #expect(!report.finishedCleanly)
        #expect(JunkRemovalReport(failedCount: 1).details == ["1 item couldn't be removed."])
        #expect(JunkRemovalReport(bytesFreed: 1, removedCount: 1).finishedCleanly)
    }

    // MARK: - Helper policy

    @Test("The helper removes a caller's own saved revisions")
    func policyAllowsOwnRevisions() throws {
        let path = kDocumentVersionsRevisionsPath + "/501/1/com.apple.documentVersions/abc.txt"
        #expect(SystemJunkDeleter.requiresHelper(path: path))
        #expect(throws: Never.self) {
            _ = try HelperDeletionPolicy.production.validateDeletionPath(path, callerUID: 501)
        }
    }

    @Test("The helper refuses another account's revisions, and any from an unknown caller")
    func policyBindsRevisionsToTheCaller() {
        let path = kDocumentVersionsRevisionsPath + "/501/1/com.apple.documentVersions/abc.txt"
        #expect(throws: HelperDeletionValidationError.self) {
            _ = try HelperDeletionPolicy.production.validateDeletionPath(path, callerUID: 502)
        }
        #expect(throws: HelperDeletionValidationError.self) {
            _ = try HelperDeletionPolicy.production.validateDeletionPath(path)
        }
    }

    @Test("A refused revision doesn't stop the rest of the batch")
    func refusedRevisionFailsAlone() throws {
        let removed = TestBox<[String]>([])
        let error = try HelperDeletionPolicy.production.removeValidatedPaths(
            [kDocumentVersionsRevisionsPath + "/502/a.txt", "/Library/Caches/ok"],
            callerUID: 501
        ) { url in removed.withLock { $0.append(url.path) } }

        #expect(error != nil)
        #expect(removed.value == ["/Library/Caches/ok"])
    }

    @Test("The helper refuses the store's own database and its folders, even from their owner")
    func policyProtectsTheStore() {
        for path in [
            kDocumentVersionsStorePath + "/db-V1/db.sqlite",
            kDocumentVersionsRevisionsPath + "/501",
            kDocumentVersionsRevisionsPath,
            kDocumentVersionsStorePath,
        ] {
            #expect(throws: HelperDeletionValidationError.self, "\(path)") {
                _ = try HelperDeletionPolicy.production.validateDeletionPath(path, callerUID: 501)
            }
        }
    }

    @Test("Only the current user's revisions are offered, never the store's database")
    func scanOffersOnlyThisUsersRevisions() {
        let mine = kDocumentVersionsStorePath + "/PerUID/\(getuid())/1/com.apple.documentVersions/a.txt"
        let theirs = kDocumentVersionsStorePath + "/PerUID/\(getuid() + 1)/1/com.apple.documentVersions/b.txt"
        let database = kDocumentVersionsStorePath + "/db-V1/db.sqlite"

        #expect(DocumentVersionsScanner.isRemovableRevision(path: mine))
        #expect(!DocumentVersionsScanner.isRemovableRevision(path: theirs))
        #expect(!DocumentVersionsScanner.isRemovableRevision(path: database))
    }
}
