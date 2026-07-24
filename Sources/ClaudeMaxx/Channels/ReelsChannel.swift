import WebKit

/// Instagram Reels (SPEC §8.1/§8.2, M4).
///
/// Scroll-only: §8.2 flags chevron selectors as "unverified guesses by
/// design... not something an agent should trust". Verified against the live
/// logged-in feed — advances land as `container DIV.x1pq812k…` in the log at
/// natural reel spacing. A real selector could still be added to
/// `nextSelectors` without touching anything else.
struct ReelsChannel: VideoFeedChannel {
    let id = "reels"
    let displayName = "Reels"
    let url = URL(string: "https://www.instagram.com/reels/")!
}
