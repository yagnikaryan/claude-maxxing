import XCTest
@testable import ClaudeMaxx

/// The daemon has no install location to record — it runs from wherever the
/// clone is — so "Start with Claude Code" finds its helper script by walking
/// up from the running binary. That arithmetic is the whole contract, and it
/// breaks silently if the build layout ever changes.
///
/// Deliberately no test drives `setEnabled`: it edits the developer's real
/// `~/.claude/settings.json`. The script's behavior (enable/disable,
/// idempotency, preserving other hooks and key order) is exercised against a
/// scratch settings file instead, via `CM_CLAUDE_DIR`.
final class StartupHookTests: XCTestCase {

    func testScriptPathResolvesRelativeToTheRunningBinary() {
        let binary = URL(fileURLWithPath: "/Users/dev/code/claude-maxxing/.build/release/ClaudeMaxx")

        XCTAssertEqual(
            StartupHook.scriptURL(forBinaryAt: binary).path,
            "/Users/dev/code/claude-maxxing/scripts/claude-maxx-hook.sh"
        )
    }

    /// `swift run` and `swift build` put the binary under a different config
    /// directory; both must resolve to the same clone.
    func testDebugAndReleaseBuildsResolveToTheSameScript() {
        let debug = URL(fileURLWithPath: "/tmp/clone/.build/debug/ClaudeMaxx")
        let release = URL(fileURLWithPath: "/tmp/clone/.build/release/ClaudeMaxx")

        XCTAssertEqual(
            StartupHook.scriptURL(forBinaryAt: debug),
            StartupHook.scriptURL(forBinaryAt: release)
        )
        XCTAssertEqual(
            StartupHook.scriptURL(forBinaryAt: debug).path,
            "/tmp/clone/scripts/claude-maxx-hook.sh"
        )
    }

    /// A clone whose path contains spaces must not be mangled — this is a
    /// URL, not a shell string, and it is handed to Process as an argv entry.
    func testHandlesPathsWithSpaces() {
        let binary = URL(fileURLWithPath: "/Users/dev/My Code/claude maxxing/.build/release/ClaudeMaxx")

        XCTAssertEqual(
            StartupHook.scriptURL(forBinaryAt: binary).path,
            "/Users/dev/My Code/claude maxxing/scripts/claude-maxx-hook.sh"
        )
    }
}
