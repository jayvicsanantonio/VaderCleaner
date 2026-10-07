// swift-tools-version: 6.2
// Package.swift
// Builds VaderCleanerCore — the app's UI-free scanners, stores, view models, and helper XPC protocol — as a library the app links.

import PackageDescription

let package = Package(
    name: "VaderCleanerCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VaderCleanerCore", targets: ["VaderCleanerCore"]),
    ],
    targets: [
        .target(name: "VaderCleanerCore"),
    ],
    swiftLanguageModes: [.v6]
)
