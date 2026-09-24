import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Short-lived cache of `SCShareableContent` (displays, apps, windows).
/// Fetching it costs tens of milliseconds, so it's warmed on launch and
/// refreshed when a hotkey fires, then reused for a brief TTL (plan §1.3).
///
/// Owned by `ScreenCaptureService` and only used from that actor —
/// `SCShareableContent` isn't `Sendable`, so it never leaves it.
nonisolated final class ShareableContentCache {
    /// Window lists change constantly; keep this short.
    static let defaultTTL: TimeInterval = 2

    private var content: SCShareableContent?
    private var fetchedAt: Date?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = ShareableContentCache.defaultTTL) {
        self.ttl = ttl
    }

    var isFresh: Bool {
        guard content != nil, let fetchedAt else { return false }
        return Date.now.timeIntervalSince(fetchedAt) < ttl
    }

    /// Cached content if still fresh, otherwise a new fetch.
    nonisolated(nonsending) func content(forceRefresh: Bool = false) async throws -> SCShareableContent {
        if !forceRefresh, isFresh, let content {
            return content
        }
        return try await refresh()
    }

    @discardableResult
    nonisolated(nonsending) func refresh() async throws -> SCShareableContent {
        let start = ContinuousClock.now
        let fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        content = fresh
        fetchedAt = .now
        Log.capture.debug("shareable content refreshed in \(start.duration(to: .now), privacy: .public): \(fresh.displays.count) displays, \(fresh.windows.count) windows")
        return fresh
    }

    func invalidate() {
        content = nil
        fetchedAt = nil
    }
}

extension Log {
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
}
