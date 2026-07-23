import Foundation

/// cm.mode values (§9.1). Owned here since SettingsStore is the only
/// current reader/writer of cm.mode; ModeManager (future) consumes this type.
enum Mode: String, CaseIterable {
    case off, ask, auto
}

/// Thin UserDefaults wrapper for all cm.* keys (SPEC §9.1).
/// No business logic, no validation beyond type coercion — callers
/// (ModeManager, PresentationController, ReadingChannel, etc.) own behavior.
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    /// Injectable for isolated testing (e.g. a throwaway UserDefaults(suiteName:)
    /// instance); production code uses the .standard-backed `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.mode: Mode.ask.rawValue,
            Keys.channel: "shorts",
            Keys.autoAdvance: true,
            Keys.showDelay: 4.0,
            Keys.dailyCapMinutes: 0,
            Keys.snapBack: true,
        ])
    }

    private enum Keys {
        static let mode = "cm.mode"
        static let channel = "cm.channel"
        static let autoAdvance = "cm.autoAdvance"
        static let showDelay = "cm.showDelay"
        static let dailyCapMinutes = "cm.dailyCapMinutes"
        static let snapBack = "cm.snapBack"
        static let windowFrame = "cm.windowFrame"
        static func scroll(_ urlHash: String) -> String { "cm.scroll.\(urlHash)" }
    }

    // default: ask
    var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: Keys.mode) }
    }

    // default: "shorts"
    var channel: String {
        get { defaults.string(forKey: Keys.channel) ?? "shorts" }
        set { defaults.set(newValue, forKey: Keys.channel) }
    }

    // default: true
    var autoAdvance: Bool {
        get { defaults.bool(forKey: Keys.autoAdvance) }
        set { defaults.set(newValue, forKey: Keys.autoAdvance) }
    }

    // default: 4.0
    var showDelay: Double {
        get { defaults.double(forKey: Keys.showDelay) }
        set { defaults.set(newValue, forKey: Keys.showDelay) }
    }

    // default: 0 (0 = off, per §9.1)
    var dailyCapMinutes: Int {
        get { defaults.integer(forKey: Keys.dailyCapMinutes) }
        set { defaults.set(newValue, forKey: Keys.dailyCapMinutes) }
    }

    // default: true
    var snapBack: Bool {
        get { defaults.bool(forKey: Keys.snapBack) }
        set { defaults.set(newValue, forKey: Keys.snapBack) }
    }

    // raw NSWindow.saveFrame(usingName:) string; nil until first drag/save.
    // No default registered (absence is meaningful — "no saved frame yet").
    var windowFrame: String? {
        get { defaults.string(forKey: Keys.windowFrame) }
        set { defaults.set(newValue, forKey: Keys.windowFrame) }
    }

    // default: 0.0 (top of article). Keyed per-article by caller-supplied hash.
    func scrollOffset(forURLHash urlHash: String) -> Double {
        defaults.double(forKey: Keys.scroll(urlHash))
    }

    func setScrollOffset(_ offset: Double, forURLHash urlHash: String) {
        defaults.set(offset, forKey: Keys.scroll(urlHash))
    }
}
