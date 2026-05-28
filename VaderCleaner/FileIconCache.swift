// FileIconCache.swift
// Lightweight NSWorkspace icon cache for table rows that need stable file-type icons without doing LaunchServices work while SwiftUI renders cells.

import AppKit
import Dispatch
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class FileIconCache {
    enum CacheKey: Hashable {
        case directory
        case extensionless
        case fileExtension(String)

        var cacheIdentifier: NSString {
            switch self {
            case .directory:
                return "directory"
            case .extensionless:
                return "extensionless"
            case .fileExtension(let fileExtension):
                return "extension:\(fileExtension)" as NSString
            }
        }
    }

    typealias IconLoader = (CacheKey) -> NSImage

    /// Bumped once per `preloadIcons` batch so SwiftUI views that call
    /// `cachedIcon(for:)` are invalidated together rather than once per
    /// inserted icon.
    private var revision = 0

    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private let placeholderIcon: NSImage
    @ObservationIgnored private let iconLoader: IconLoader
    @ObservationIgnored private let workQueue = DispatchQueue(label: "com.personal.VaderCleaner.file-icon-cache",
                                                              qos: .userInitiated)

    init(
        placeholderIcon: NSImage = NSWorkspace.shared.icon(for: .item),
        iconLoader: @escaping IconLoader = FileIconCache.defaultIcon(for:)
    ) {
        self.placeholderIcon = placeholderIcon
        self.iconLoader = iconLoader
    }

    func cachedIcon(for url: URL) -> NSImage {
        // Observation framework only re-renders a view when it reads a
        // tracked property; touching `revision` here subscribes any
        // caller's body to the per-batch bump that `preloadIcons` issues.
        _ = revision
        let key = Self.cacheKey(for: url)
        return cache.object(forKey: key.cacheIdentifier) ?? placeholderIcon
    }

    @discardableResult
    func preloadIcons(for urls: [URL]) async -> Int {
        let keys = Set(urls.map(Self.cacheKey(for:)))
            .filter { cache.object(forKey: $0.cacheIdentifier) == nil }
        guard !keys.isEmpty else { return 0 }

        let iconLoader = self.iconLoader
        let workQueue = self.workQueue
        let loadedIcons = await withCheckedContinuation { continuation in
            workQueue.async {
                let loadedIcons = keys.map { LoadedIcon(key: $0, icon: iconLoader($0)) }
                continuation.resume(returning: loadedIcons)
            }
        }

        var addedCount = 0
        for loadedIcon in loadedIcons where cache.object(forKey: loadedIcon.key.cacheIdentifier) == nil {
            cache.setObject(loadedIcon.icon, forKey: loadedIcon.key.cacheIdentifier)
            addedCount += 1
        }
        if addedCount > 0 {
            revision += 1
        }

        return addedCount
    }

    private static func cacheKey(for url: URL) -> CacheKey {
        if url.hasDirectoryPath {
            return .directory
        }

        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            return .extensionless
        }

        return .fileExtension(fileExtension)
    }

    private nonisolated static func defaultIcon(for key: CacheKey) -> NSImage {
        switch key {
        case .directory:
            return NSWorkspace.shared.icon(for: .folder)
        case .extensionless:
            return NSWorkspace.shared.icon(for: .item)
        case .fileExtension(let fileExtension):
            let type = UTType(filenameExtension: fileExtension) ?? .item
            return NSWorkspace.shared.icon(for: type)
        }
    }

    private struct LoadedIcon {
        let key: CacheKey
        let icon: NSImage
    }
}
