// DiskScannerTests.swift
// Drives DiskScanner against real temp directories to verify tree shape, size aggregation, symlink avoidance, permission tolerance, and progress reporting.

import XCTest
@testable import VaderCleaner

/// Integration tests for `DiskScanner`. We use real temp directories rather
/// than a mock file system because the scanner's whole job is to read what's
/// actually on disk — mocking `FileManager` would test the mock, not the
/// behaviour we ship.
final class DiskScannerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try TestHelpers.createTempDirectory()
    }

    override func tearDown() {
        if let tempRoot {
            TestHelpers.tearDownTempDirectory(tempRoot)
        }
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Tree shape and size aggregation

    /// A nested fixture (`a/1.bin` (32B) + `a/b/2.bin` (64B)) must produce a
    /// tree where every directory's reported size equals the sum of its
    /// descendants' sizes, and the leaves carry their on-disk byte count.
    /// This locks both the recursion shape and the bottom-up rollup.
    func test_scan_buildsCorrectTreeForKnownDirectory() async throws {
        let aDir = tempRoot.appendingPathComponent("a", isDirectory: true)
        let bDir = aDir.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "1.bin", size: 32, in: aDir)
        try TestHelpers.createDummyFile(named: "2.bin", size: 64, in: bDir)

        let scanner = DiskScanner()
        let root = try await scanner.scan(root: tempRoot, progress: { _ in })

        // Root's only child should be `a`.
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.children.count, 1)
        let aNode = try XCTUnwrap(root.children.first { $0.name == "a" })
        XCTAssertTrue(aNode.isDirectory)

        // `a` has one file (32B) and one subdir.
        let oneBin = try XCTUnwrap(aNode.children.first { $0.name == "1.bin" })
        XCTAssertFalse(oneBin.isDirectory)
        XCTAssertEqual(oneBin.size, 32)

        let bNode = try XCTUnwrap(aNode.children.first { $0.name == "b" })
        XCTAssertTrue(bNode.isDirectory)

        let twoBin = try XCTUnwrap(bNode.children.first { $0.name == "2.bin" })
        XCTAssertEqual(twoBin.size, 64)

        // Rollup: b = 64, a = 32 + 64 = 96, root = 96.
        XCTAssertEqual(bNode.size, 64)
        XCTAssertEqual(aNode.size, 96)
        XCTAssertEqual(root.size, 96)
    }

    func test_scan_treatsPackageDirectoryAsLeafWithRolledUpSize() async throws {
        let package = tempRoot.appendingPathComponent("Photos.app", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "a.bin", size: 32, in: contents)
        try TestHelpers.createDummyFile(named: "b.bin", size: 64, in: contents)

        var progressCounts: [Int] = []
        let scanner = DiskScanner()
        let root = try await scanner.scan(root: tempRoot, progress: { count in
            progressCounts.append(count)
        })

        let packageNode = try XCTUnwrap(root.children.first { $0.name == "Photos.app" })
        XCTAssertFalse(packageNode.isDirectory, "Packages render as leaf tiles, not drill-down folders")
        XCTAssertTrue(packageNode.children.isEmpty)
        XCTAssertEqual(packageNode.size, 96)
        XCTAssertEqual(root.size, 96)
        XCTAssertEqual(progressCounts.last, 2, "Progress should still count regular files inside package rollups")
    }

    // MARK: - Symlink handling

    /// A symlink whose target is the scan's own root would cause infinite
    /// recursion if followed. The scanner must complete and the link's
    /// target contents must not appear under the link's path.
    ///
    /// Policy note: this test deliberately uses a directory symlink. The
    /// scanner's documented behaviour is to skip *all* symlinks (file and
    /// directory) — see `DiskScanner` for the rationale. Locking the
    /// directory case here covers the cycle-prevention guarantee that the
    /// prompt explicitly calls out.
    func test_scan_doesNotFollowSymlinksAndAvoidsCycles() async throws {
        let realDir = tempRoot.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "leaf.bin", size: 16, in: realDir)

        // Cycle: tempRoot/real/loopback -> tempRoot
        let loopback = realDir.appendingPathComponent("loopback")
        try FileManager.default.createSymbolicLink(at: loopback, withDestinationURL: tempRoot)

        let scanner = DiskScanner()
        let root = try await scanner.scan(root: tempRoot, progress: { _ in })

        let realNode = try XCTUnwrap(root.children.first { $0.name == "real" })
        // Only the leaf file should appear; the symlink is skipped entirely
        // (not followed and not added as a stub).
        let names = realNode.children.map(\.name).sorted()
        XCTAssertEqual(names, ["leaf.bin"])
        XCTAssertEqual(realNode.size, 16)
    }

    // MARK: - Permission denied

    /// A subdirectory the current user cannot read must surface as a node
    /// with `isAccessible == false` and `size == 0`, and the scan of its
    /// peers must continue. Without this, one locked Library subfolder
    /// would abort the whole volume scan.
    ///
    /// Skipped when the current process can still read a `chmod 000`
    /// directory (e.g. running as root inside a CI container) — the test
    /// would fail spuriously and the behaviour is unobservable in that
    /// environment.
    func test_scan_marksPermissionDeniedDirectoriesAsInaccessible() async throws {
        let readable = tempRoot.appendingPathComponent("readable", isDirectory: true)
        let locked = tempRoot.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "open.bin", size: 8, in: readable)
        try TestHelpers.createDummyFile(named: "secret.bin", size: 999, in: locked)

        // Restore permissions in a defer so teardown can actually delete the
        // temp tree — `try?` removal on a chmod 000 directory silently fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o000))],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: locked.path
            )
        }

        // Confirm the precondition: this process actually cannot read the
        // locked directory. If it can (root, weird sandbox), the assertion
        // we want to make is unobservable.
        let canStillRead = (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) != nil
        try XCTSkipIf(canStillRead, "Current process can read chmod 000 directories — cannot exercise the deny path here.")

        let scanner = DiskScanner()
        let root = try await scanner.scan(root: tempRoot, progress: { _ in })

        let readableNode = try XCTUnwrap(root.children.first { $0.name == "readable" })
        XCTAssertEqual(readableNode.size, 8, "Sibling enumeration must continue after a permission failure")

        let lockedNode = try XCTUnwrap(root.children.first { $0.name == "locked" })
        XCTAssertFalse(lockedNode.isAccessible, "A directory we couldn't read must be marked inaccessible")
        XCTAssertEqual(lockedNode.size, 0, "Inaccessible directories report zero bytes — we never enumerated them")
        XCTAssertTrue(lockedNode.children.isEmpty)
    }

    // MARK: - Symlinked root

    /// macOS exposes `/tmp`, `/var`, and `/etc` as symlinks to
    /// `/private/...`. If the user starts Space Lens at one of those
    /// (or at any user-created directory symlink they think of as
    /// "the folder"), we must scan the *target*, not return a single
    /// zero-byte file node. Inside the walk we still skip symlinks
    /// (cycle prevention + no double-counting) — this asserts the
    /// asymmetry at the root is real and verified.
    func test_scan_resolvesSymlinkedRootToTarget() async throws {
        let target = tempRoot.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "leaf.bin", size: 16, in: target)

        let symlinkRoot = tempRoot.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: target)

        let scanner = DiskScanner()
        let root = try await scanner.scan(root: symlinkRoot, progress: { _ in })

        XCTAssertTrue(root.isDirectory, "Resolved root should be treated as a directory, not a symlink leaf")
        XCTAssertEqual(root.size, 16, "Tree must reflect the target's contents, not 0 bytes")
        XCTAssertEqual(root.children.map(\.name).sorted(), ["leaf.bin"])
    }

    // MARK: - Missing root

    /// A root that exists *and* has readable metadata (so the upfront
    /// `resourceValues` validation passes) but whose contents the user
    /// can't enumerate — `chmod 000`, sandbox-protected folders, certain
    /// volume-root permission denials — must throw rather than emit a
    /// single inaccessible node. There is no parent to render the locked
    /// state, so the VM would otherwise land in `.ready(emptyTree)` and
    /// the upcoming UI would lie that the scan succeeded.
    ///
    /// Skipped when the current process can read `chmod 000` directories
    /// (root in a CI container, etc.); same gating as the descendant
    /// permission test.
    func test_scan_throwsWhenRootIsUnreadable() async throws {
        let unreadableRoot = tempRoot.appendingPathComponent("locked-root", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableRoot, withIntermediateDirectories: true)
        try TestHelpers.createDummyFile(named: "secret.bin", size: 8, in: unreadableRoot)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o000))],
            ofItemAtPath: unreadableRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: unreadableRoot.path
            )
        }

        let canStillRead = (try? FileManager.default.contentsOfDirectory(atPath: unreadableRoot.path)) != nil
        try XCTSkipIf(canStillRead, "Current process can read chmod 000 directories — cannot exercise the deny path here.")

        let scanner = DiskScanner()
        do {
            _ = try await scanner.scan(root: unreadableRoot, progress: { _ in })
            XCTFail("Expected scan to throw for an unreadable root")
        } catch let error as DiskScanError {
            XCTAssertEqual(error, .rootInaccessible(unreadableRoot))
        } catch {
            XCTFail("Expected DiskScanError.rootInaccessible, got \(error)")
        }
    }

    /// A root URL that doesn't exist (deleted directory, unmounted
    /// volume) must surface as a thrown `DiskScanError.rootInaccessible`
    /// rather than a successful empty `DiskNode`. Without this guarantee
    /// the upcoming UI would render a zero-byte tree as a "scan
    /// finished, nothing here" state instead of letting the user know
    /// the scan couldn't run.
    func test_scan_throwsWhenRootIsMissing() async {
        let missingRoot = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let scanner = DiskScanner()

        do {
            _ = try await scanner.scan(root: missingRoot, progress: { _ in })
            XCTFail("Expected scan to throw for a missing root")
        } catch let error as DiskScanError {
            XCTAssertEqual(error, .rootInaccessible(missingRoot))
        } catch {
            XCTFail("Expected DiskScanError.rootInaccessible, got \(error)")
        }
    }

    // MARK: - Progress

    /// The scanner must invoke its progress callback as it processes files,
    /// with a monotonically non-decreasing count, and the final count must
    /// equal the total number of regular files in the fixture. The Space
    /// Lens UI uses this to drive its progress bar.
    func test_scan_reportsProgressAsItScans() async throws {
        let fileCount = 5
        try TestHelpers.createDummyFiles(count: fileCount, size: 16, in: tempRoot)

        var observed: [Int] = []
        let scanner = DiskScanner()
        _ = try await scanner.scan(root: tempRoot, progress: { count in
            observed.append(count)
        })

        XCTAssertFalse(observed.isEmpty, "Progress callback must be invoked at least once")
        XCTAssertEqual(observed.last, fileCount, "Final progress count should equal the regular-file count")
        // Monotonic non-decreasing.
        for (lhs, rhs) in zip(observed, observed.dropFirst()) {
            XCTAssertLessThanOrEqual(lhs, rhs, "Progress counts must never decrease")
        }
    }
}
