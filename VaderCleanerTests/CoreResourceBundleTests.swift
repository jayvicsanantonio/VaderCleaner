// CoreResourceBundleTests.swift
// Pins that VaderCleanerCore's string tables still resolve inside the app, where its resource bundle ships in Contents/Resources rather than beside a test runner.

import Foundation
import Testing
@testable import VaderCleanerCore

/// The package suite proves the core reads its own tables hostless; this is
/// the other half. Here `Bundle.main` is the app, which no longer carries
/// these keys, so a pass means the lookup found the core's bundle inside
/// VaderCleaner.app — and a bundle that failed to ship would trap in
/// `Bundle.module` instead.
@Suite struct CoreResourceBundleTests {

    @Test func identifierKeysResolveInsideTheApp() {
        #expect(SystemStatsFormatters.pressureLabel(for: .nominal) == "Normal")
    }

    @Test func pluralsResolveInsideTheApp() {
        let finding = CareFinding(payload: .loginItems([LoginItem(id: "a", name: "Agent", isEnabled: true)]))
        #expect(CareFindingCopy.metric(for: finding) == "1 login item")
    }
}
