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

    /// Split out so the path arithmetic is asserted directly: it depends on
    /// the binary sitting exactly three levels below the repo root
    /// (`.build/<config>/ClaudeMaxx`), which is easy to break silently.
    static func scriptURL(forBinaryAt binary: URL) -> URL {
        binary
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()   // .build/<config>
            .deletingLastPathComponent()   // .build
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("scripts/claude-maxx-hook.sh")
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
