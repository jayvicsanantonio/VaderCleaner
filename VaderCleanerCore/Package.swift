// swift-tools-version: 6.2
// Package.swift
// Builds VaderCleanerCore — the app's UI-free scanners, stores, view models, and helper XPC protocol — as a library the app links, with a test target that runs without a host app.

import PackageDescription

let package = Package(
    name: "VaderCleanerCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VaderCleanerCore", targets: ["VaderCleanerCore"]),
    ],
    targets: [
        // The core's own string tables. Its lookups pass `bundle: .module`, so
        // they resolve the same inside the app and under `swift test`, where
        // `Bundle.main` is the test runner and has no tables at all.
        .target(name: "VaderCleanerCore", resources: [.process("Resources")]),
        .testTarget(name: "VaderCleanerCoreTests", dependencies: ["VaderCleanerCore"]),
    ],
    swiftLanguageModes: [.v6]
)
