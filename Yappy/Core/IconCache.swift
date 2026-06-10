//
//  IconCache.swift
//  Yappy
//

import AppKit

/// Resolves and caches app icons by bundle identifier for the history list.
/// Misses are cached too, so unresolvable bundle ids don't re-query the
/// workspace on every row render.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var cache: [String: NSImage?] = [:]

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] {
            return cached
        }

        var resolved: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            resolved = icon
        }
        cache[bundleID] = resolved
        return resolved
    }
}
