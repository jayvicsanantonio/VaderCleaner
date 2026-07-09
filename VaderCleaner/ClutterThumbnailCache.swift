// ClutterThumbnailCache.swift
// Process-wide cache of generated Quick Look thumbnails so navigating away from and back to My Clutter reuses already-rendered images instead of regenerating them.

import AppKit

/// A small process-wide cache of `NSImage` thumbnails keyed by file path and
/// requested point size. My Clutter's section view is torn down and rebuilt on
/// every sidebar navigation (`ContentView` keys the detail pane by section), so
/// without a cache each return trip re-fires a Quick Look generation for every
/// dashboard thumbnail — expensive for videos and large images. Seeding a view
/// synchronously from this cache lets a repeat visit paint its thumbnails
/// instantly and do no Quick Look work.
///
/// Backed by `NSCache`, which is thread-safe and evicts under memory pressure,
/// so the cache never grows unbounded.
enum ClutterThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Generous but bounded: a dashboard shows a handful of thumbnails and a
        // manager preview a few more, so a few hundred entries covers heavy use
        // while still letting the OS reclaim memory when needed.
        cache.countLimit = 512
        return cache
    }()

    /// Cache key combines the path and point size — the same file is requested
    /// at different sizes for the card corner vs. the manager preview.
    private static func key(_ url: URL, _ pointSize: CGFloat) -> NSString {
        "\(url.path)#\(Int(pointSize))" as NSString
    }

    /// The cached thumbnail for `url` at `pointSize`, or `nil` on a miss. Safe to
    /// call synchronously from a view initializer.
    static func cached(_ url: URL, pointSize: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, pointSize))
    }

    /// Store a freshly generated thumbnail for reuse on the next visit.
    static func store(_ image: NSImage, for url: URL, pointSize: CGFloat) {
        cache.setObject(image, forKey: key(url, pointSize))
    }
}
