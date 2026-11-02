// ClutterThumbnailLoadTests.swift
// Pins that a superseded thumbnail load neither returns its image nor poisons the shared cache, so a slow result can't overwrite the picture of a newer file.

import AppKit
import Foundation
import Testing
@testable import VaderCleanerCore

@Suite struct ClutterThumbnailLoadTests {

    private func uniqueURL() -> URL {
        URL(fileURLWithPath: "/tmp/clutter-thumb-tests/\(UUID().uuidString).jpg")
    }

    @Test func aCompletedLoadReturnsAndCachesItsImage() async {
        let url = uniqueURL()
        let image = NSImage(size: NSSize(width: 4, height: 4))

        let loaded = await ClutterThumbnailCache.load(url, pointSize: 92, generate: { _, _ in image })

        #expect(loaded === image)
        #expect(ClutterThumbnailCache.cached(url, pointSize: 92) === image)
    }

    @Test func aCancelledLoadReturnsNothingAndCachesNothing() async {
        let url = uniqueURL()
        let gate = SuspendingCallGate()
        let image = TestBox(NSImage(size: NSSize(width: 4, height: 4)))

        let load = Task {
            await ClutterThumbnailCache.load(url, pointSize: 92, generate: { _, _ in
                await gate.hold()
                return image.value
            })
        }
        #expect(await pollUntil { gate.isHolding })
        load.cancel()
        gate.open()

        #expect(await load.value == nil)
        #expect(ClutterThumbnailCache.cached(url, pointSize: 92) == nil)
    }
}
