import WebKit

/// TikTok's For You feed (SPEC §8.1/§8.2, M4). Works logged-out (verified
/// against the live site).
///
/// Scroll-only for the same reason as `ReelsChannel`; an attempt to find the
/// real chevron hit a narrow-viewport variant of the page that never exposed
/// an accessible name.
struct TikTokChannel: VideoFeedChannel {
    let id = "tiktok"
    let displayName = "TikTok"
    let url = URL(string: "https://www.tiktok.com/foryou")!
}
