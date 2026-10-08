// ObservationRecordingTests.swift
// Tests the framework-agnostic polling helper that backs waitUntil, plus its own Swift Testing rewrite.

import Testing

@MainActor
@Suite
struct ObservationRecordingTests {

    @Test
    func pollUntil_returnsTrueImmediately_whenConditionAlreadyHolds() async {
        let result = await pollUntil(timeout: .seconds(1)) { true }
        #expect(result)
    }

    @Test
    func pollUntil_returnsFalse_whenConditionNeverHolds() async {
        let result = await pollUntil(timeout: .milliseconds(100), pollInterval: .milliseconds(20)) { false }
        #expect(!result)
    }

    @Test
    func pollUntil_returnsTrue_onceAMutationLandsPartway() async {
        var flag = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            flag = true
        }
        let result = await pollUntil(timeout: .seconds(1), pollInterval: .milliseconds(10)) { flag }
        #expect(result)
    }
}
