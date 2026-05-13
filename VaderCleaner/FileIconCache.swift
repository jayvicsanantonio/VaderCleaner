// FileIconCache.swift
// Lightweight NSWorkspace icon cache for table rows that need stable file-type icons without doing LaunchServices work while SwiftUI renders cells.

import AppKit
import Combine
import UniformTypeIdentifiers

final class FileIconCache: ObservableObject {
    typealias IconLoader = (String) -> NSImage

    @Published private var revision = 0

    private let cache = NSCache<NSString, NSImage>()
    private let placeholderIcon: NSImage
    private let iconLoader: IconLoader

    init(
        placeholderIcon: NSImage = NSWorkspace.shared.icon(for: .item),
        iconLoader: @escaping IconLoader = FileIconCache.defaultIcon(for:)
    ) {
        self.placeholderIcon = placeholderIcon
        self.iconLoader = iconLoader
    }

    func cachedIcon(for url: URL) -> NSImage {
        let key = Self.cacheKey(for: url)
        return cache.object(forKey: key as NSString) ?? placeholderIcon
    }

    @discardableResult
    func preloadIcons(for urls: [URL]) -> Int {
        var addedCount = 0
        let keys = Set(urls.map(Self.cacheKey(for:)))

        for key in keys where cache.object(forKey: key as NSString) == nil {
            cache.setObject(iconLoader(key), forKey: key as NSString)
            addedCount += 1
        }

        if addedCount > 0 {
            revision += 1
        }

        return addedCount
    }

    private static func cacheKey(for url: URL) -> String {
        if url.hasDirectoryPath {
            return "directory"
        }

        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            return "extensionless"
        }

        return "extension:\(fileExtension)"
    }

    private static func defaultIcon(for key: String) -> NSImage {
        switch key {
        case "directory":
            return NSWorkspace.shared.icon(for: .folder)
        case "extensionless":
            return NSWorkspace.shared.icon(for: .item)
        default:
            let fileExtension = key.replacingOccurrences(of: "extension:", with: "")
            return NSWorkspace.shared.icon(forFileType: fileExtension)
        }
    }
}
