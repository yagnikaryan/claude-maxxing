import XCTest
@testable import ClaudeMaxx

/// The daemon has no install location to record — it runs from wherever the
/// clone is — so "Start with Claude Code" finds its helper script by searching
/// upward from the running binary.
///
/// These build real directory trees rather than asserting against literal
/// paths. An earlier version of this test did the latter, passed, and shipped
/// a toggle that was broken in exactly the layout the installer produces:
/// SwiftPM makes `.build/release` a symlink into `.build/<triple>/release`, so
/// a fixed-depth walk landed one directory short.
///
/// Deliberately no test drives `setEnabled`: it would edit the developer's
/// real `~/.claude/settings.json`. The script's own behavior is exercised
/// against a scratch settings file via `CM_CLAUDE_DIR`.
final class StartupHookTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cm-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates `<clone>/scripts/claude-maxx-hook.sh` and returns the clone.
    private func makeClone(named name: String) throws -> URL {
        let clone = root.appendingPathComponent(name)
        let scripts = clone.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: scripts.appendingPathComponent("claude-maxx-hook.sh").path, contents: Data())
        return clone
    }

    func testFindsScriptFromADebugBuild() throws {
        let clone = try makeClone(named: "clone")
        let binary = clone.appendingPathComponent(".build/debug/ClaudeMaxx")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)

        XCTAssertEqual(
            StartupHook.scriptURL(forBinaryAt: binary).resolvingSymlinksInPath().path,
            clone.appendingPathComponent("scripts/claude-maxx-hook.sh").resolvingSymlinksInPath().path
        )
    }

    /// Regression: the release layout SwiftPM actually produces, where
    /// `.build/release` is a symlink one level shallower than its target.
    func testFindsScriptThroughTheReleaseSymlink() throws {
        let clone = try makeClone(named: "clone")
        let real = clone.appendingPathComponent(".build/arm64-apple-macosx/release")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: real.appendingPathComponent("ClaudeMaxx").path, contents: Data())
        try FileManager.default.createSymbolicLink(
            at: clone.appendingPathComponent(".build/release"),
            withDestinationURL: real
        )

        let viaSymlink = clone.appendingPathComponent(".build/release/ClaudeMaxx")

        XCTAssertEqual(
            StartupHook.scriptURL(forBinaryAt: viaSymlink).resolvingSymlinksInPath().path,
            clone.appendingPathComponent("scripts/claude-maxx-hook.sh").resolvingSymlinksInPath().path,
            "release builds resolve one level deeper — the toggle silently died on this"
        )
    }

    /// A clone whose path contains spaces must survive: this is a URL handed
    /// to Process as an argv entry, not a shell string.
    func testHandlesPathsWithSpaces() throws {
        let clone = try makeClone(named: "my clone dir")
        let binary = clone.appendingPathComponent(".build/debug/ClaudeMaxx")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)

        XCTAssertEqual(
            StartupHook.scriptURL(forBinaryAt: binary).resolvingSymlinksInPath().path,
            clone.appendingPathComponent("scripts/claude-maxx-hook.sh").resolvingSymlinksInPath().path
        )
    }

    /// Nothing to find: still yields a plausible path to name in the log
    /// rather than walking to the filesystem root or crashing.
    func testFallsBackWhenNoCloneIsFound() {
        let orphan = root.appendingPathComponent("nowhere/.build/debug/ClaudeMaxx")

        XCTAssertTrue(
            StartupHook.scriptURL(forBinaryAt: orphan).path.hasSuffix("scripts/claude-maxx-hook.sh")
        )
    }
}
