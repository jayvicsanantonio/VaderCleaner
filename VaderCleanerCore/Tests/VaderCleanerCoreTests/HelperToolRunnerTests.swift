// HelperToolRunnerTests.swift
// Pins how the helper runs system tools: exit statuses become errors, a tool past its time limit is stopped even if it ignores SIGTERM, and a tool can't run twice at once.

import Foundation
import Testing
@testable import VaderCleanerCore

@Suite
struct HelperToolRunnerTests {

    @Test
    func execute_returnsNothingWhenTheToolSucceeds() {
        #expect(HelperToolRunner.execute(executable: "/usr/bin/true", arguments: []) == nil)
    }

    @Test
    func execute_reportsANonZeroExitInTheToolDomain() throws {
        let error = try #require(HelperToolRunner.execute(executable: "/usr/bin/false", arguments: [])) as NSError

        #expect(error.domain == HelperErrorDomain.tool)
        #expect(error.code == 1)
    }

    @Test
    func execute_returnsTheLaunchErrorForAMissingTool() {
        #expect(HelperToolRunner.execute(executable: "/nonexistent/tool", arguments: []) != nil)
    }

    @Test
    func execute_stopsAToolPastItsTimeLimit() throws {
        let clock = ContinuousClock()
        let started = clock.now

        let error = try #require(HelperToolRunner.execute(
            executable: "/bin/sleep",
            arguments: ["30"],
            timeout: .milliseconds(100)
        )) as NSError

        #expect(error.code == Int(ETIMEDOUT))
        #expect(started.duration(to: clock.now) < .seconds(10))
    }

    @Test
    func execute_killsAToolThatIgnoresSIGTERM() throws {
        let clock = ContinuousClock()
        let started = clock.now

        // `exec` so the ignored signal is held by the process being waited on.
        let error = try #require(HelperToolRunner.execute(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"],
            timeout: .milliseconds(200),
            terminationGrace: .milliseconds(200)
        )) as NSError

        #expect(error.code == Int(ETIMEDOUT))
        #expect(started.duration(to: clock.now) < .seconds(10))
    }

    @Test
    func runningExecutables_refusesAToolUntilItsRunIsReleased() {
        let running = RunningExecutables()

        #expect(running.claim(["/usr/bin/mdutil"]))
        #expect(!running.claim(["/usr/bin/mdutil"]))
        #expect(!running.claim(["/usr/bin/mdutil", "/usr/bin/tmutil"]), "a partial overlap is refused whole")
        #expect(running.claim(["/usr/bin/tmutil"]), "the refused claim took nothing")

        running.release(["/usr/bin/mdutil"])
        #expect(running.claim(["/usr/bin/mdutil"]))
    }

    @Test
    func alreadyRunningError_isNotInTheToolDomain() {
        let error = HelperToolRunner.alreadyRunningError(["/usr/bin/mdutil"]) as NSError

        #expect(error.domain == HelperErrorDomain.conflict)
    }
}
