import Foundation

/// The menu bar's "Start with Claude Code" toggle, backing the `SessionStart`
/// hook in `~/.claude/settings.json`.
///
/// This replaces an earlier "Launch at Login" item. A login item is the wrong
/// shape for this project: with no packaged `.app`, `SMAppService` registers
/// the *path of the running executable*, which goes stale on every clean or
/// release rebuild, and it would keep a daemon alive all day for something
/// that only reacts to Claude Code. Tying startup to Claude's own session
/// instead means the daemon's lifetime matches the only thing it responds to,
/// and nothing is registered with the OS that can rot.
///
/// The actual JSON editing lives in `scripts/claude-maxx-hook.sh` rather than
/// here. Foundation dictionaries are unordered, so round-tripping the user's
/// `settings.json` through `JSONSerialization` would silently reorder every
/// key in a file they may well have in version control; Python's json module
/// preserves insertion order. Shelling out keeps all edits to that file going
/// through one order-preserving, atomically-written path.
enum StartupHook {

    /// Located relative to the running binary (`<repo>/.build/<config>/ClaudeMaxx`),
    /// so a moved or renamed clone still resolves — there is no install
    /// location to record, and nothing to go stale the way a login item does.
    static var scriptURL: URL {
        scriptURL(forBinaryAt: URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    /// Searches upward for the script rather than assuming a fixed depth.
    ///
    /// Counting parent directories looked fine and was wrong: SwiftPM makes
    /// `.build/release` a symlink to `.build/<triple>/release`, so resolving
    /// it yields a path one level deeper than a debug build and a fixed walk
    /// landed on `.build/scripts/…`. That silently disabled the whole toggle
    /// in release builds — the layout the installer produces — while unit
    /// tests over literal paths still passed.
    ///
    /// Falls back to the unresolved path when the search comes up empty, so a
    /// missing script still produces a sensible name in the log.
    static func scriptURL(forBinaryAt binary: URL) -> URL {
        let relative = "scripts/claude-maxx-hook.sh"
        var directory = binary.resolvingSymlinksInPath().deletingLastPathComponent()

        // Deep enough for `.build/<triple>/<config>/` and then some; bounded
        // so a binary outside a clone can't walk to the filesystem root.
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }   // reached /
            directory = parent
        }

        return binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }

    /// Queried live on every menu open rather than cached, so editing
    /// `settings.json` by hand (or running `install.sh`) is reflected the next
    /// time the menu is opened — mirrors how mode/channel state is refreshed.
    static var isEnabled: Bool {
        run(action: "status") == "enabled"
    }

    /// Fail-open like the rest of the daemon: a toggle that can't be written
    /// reports failure to stderr and leaves the menu unchanged rather than
    /// crashing. Returns the state actually in effect afterwards.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        run(action: enabled ? "enable" : "disable") == "enabled"
    }

    private static func run(action: String) -> String {
        let script = scriptURL
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            cmLog("StartupHook: \(script.path) is missing or not executable")
            return ""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, action]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // errors surface via the empty result, not the user's terminal

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus != 0 {
                cmLog("StartupHook: \(action) failed (exit \(process.terminationStatus))")
            }
            return output
        } catch {
            cmLog("StartupHook: could not run \(script.path): \(error)")
            return ""
        }
    }
}
