import WebKit

/// YouTube Shorts (SPEC §8.1/§8.2). Highest DOM stability of the three video
/// platforms, so it was built first (§15 decision #10) and is the only one
/// with a verified next-control selector.
struct ShortsChannel: VideoFeedChannel {
    let id = "shorts"
    let displayName = "Shorts"
    let url = URL(string: "https://www.youtube.com/shorts/")!

    /// Clicking the site's real control beats scrolling — it advances exactly
    /// one item.
    let nextSelectors = [
        "#navigation-button-down button",
        "button[aria-label=\"Next video\"]",
    ]
}
