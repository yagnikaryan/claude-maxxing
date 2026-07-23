import Foundation

/// Single source of truth for "enabled channels" (SPEC §12 M2 task 11/12).
/// Consumed by `ChipPanel` (one button per channel), `Orchestrator`
/// (`presentWindow()`'s `settings.channel` → `ContentChannel` resolution),
/// and `Menu` (channel selector + per-channel stats breakout).
///
/// Order is fixed — Shorts, X, Reading — and is a *display* order, not a
/// ranking: it matches file-discovery order in `Channels/` and stays stable
/// across runs so menu items and per-channel stats lines don't reshuffle.
enum ChannelRegistry {
    static let all: [ContentChannel] = [ShortsChannel(), XFeedChannel(), ReadingChannel()]

    /// `nil` when `id` matches no registered channel (e.g. a stale
    /// `cm.channel` value from a channel that was since removed) — callers
    /// fall back to `all.first`.
    static func channel(withID id: String) -> ContentChannel? {
        all.first { $0.id == id }
    }
}
