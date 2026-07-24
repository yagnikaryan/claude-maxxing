import AppKit

/// Menu bar surface (SPEC §12 M2 task 12, §9.3). Owns the `NSStatusItem` and
/// its `NSMenu`: the cheapest stats surface ("menu bar — disabled first menu
/// item... refreshed on IDLE"), mode selection, and the channel picker.
/// Mode/channel writes go straight through the same `SettingsStore` the
/// `/cmd` HTTP path uses, so persistence and behavior stay identical
/// regardless of which surface changed them.
final class Menu: NSObject, NSMenuDelegate {
    private let settings: SettingsStore
    private let stats: StatsStore
    private let orchestrator: Orchestrator
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(settings: SettingsStore = .shared, stats: StatsStore = .shared, orchestrator: Orchestrator) {
        self.settings = settings
        self.stats = stats
        self.orchestrator = orchestrator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.title = "CM"
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIdle),
            name: .claudeMaxxDidBecomeIdle,
            object: nil
        )
    }

    // MARK: NSMenuDelegate

    /// Refresh right before display too, so a menu opened without an
    /// intervening IDLE transition (e.g. nothing has run yet today) still
    /// shows live state.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    /// `claudeMaxxDidBecomeIdle` is posted on Orchestrator's private
    /// background queue — hop to main before touching AppKit.
    @objc private func handleIdle() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildMenu()
        }
    }

    // MARK: Build

    private func rebuildMenu() {
        menu.removeAllItems()

        for item in statsItems() {
            menu.addItem(item)
        }
        let dashboard = NSMenuItem(title: "Stats Dashboard…", action: #selector(openDashboard), keyEquivalent: "")
        dashboard.target = self
        menu.addItem(dashboard)
        menu.addItem(.separator())

        // First-run setup / debug entry point (§8.1, §14): opens the feed
        // window on demand, bypassing the showDelay debounce and independent
        // of any active Claude Code session, so a user can log into a
        // channel's platform — or a developer can eyeball the window —
        // without waiting on a real prompt. Safe to leave open indefinitely;
        // nothing auto-hides it (SPEC §6's IDLE transitions only fire from
        // an active wait or /cmd off).
        let showNow = NSMenuItem(title: "Show Window Now", action: #selector(showWindowNow), keyEquivalent: "")
        showNow.target = self
        menu.addItem(showNow)
        menu.addItem(.separator())

        for mode in Mode.allCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = settings.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for channel in ChannelRegistry.all {
            let item = NSMenuItem(title: channel.displayName, action: #selector(selectChannel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = channel.id
            item.state = settings.channel == channel.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let startupItem = NSMenuItem(
            title: "Start with Claude Code",
            action: #selector(toggleStartupHook),
            keyEquivalent: ""
        )
        startupItem.target = self
        startupItem.state = StartupHook.isEnabled ? .on : .off
        menu.addItem(startupItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Claude Maxx", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Stats (§9.3, build item 12)

    /// Single flat line by default: `"Today: Xm content / Ym waiting (Z
    /// waits)"` (§9.3's example, verbatim). Once more than one channel has
    /// logged a `content` event today, breaks into a waiting-only header
    /// plus one indented per-channel line (build item 12's AC) — channel
    /// order follows `ChannelRegistry.all` so the breakout is stable run to
    /// run.
    private func statsItems() -> [NSMenuItem] {
        let daily = stats.dailyStats(for: Date())
        let waitMinutes = Int(daily.waitSeconds / 60)
        let contentEvents = stats.events(on: Date()).filter { $0.type == .content }
        let channelIDsWithData = Set(contentEvents.compactMap(\.channel))

        guard channelIDsWithData.count > 1 else {
            let contentMinutes = Int(daily.contentSeconds / 60)
            return [disabledItem("Today: \(contentMinutes)m content / \(waitMinutes)m waiting (\(daily.waits) waits)")]
        }

        var items = [disabledItem("Today: \(waitMinutes)m waiting (\(daily.waits) waits)")]
        for channel in ChannelRegistry.all where channelIDsWithData.contains(channel.id) {
            let seconds = contentEvents
                .filter { $0.channel == channel.id }
                .reduce(0) { $0 + ($1.seconds ?? 0) }
            items.append(disabledItem("  \(channel.displayName): \(Int(seconds / 60))m"))
        }
        return items
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Mode else { return }
        settings.mode = mode
        if mode == .off {
            orchestrator.commandOff()   // mirrors Router's /cmd off path
        }
    }

    @objc private func selectChannel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        cmLog("menu: channel selected \(id)")
        settings.channel = id
        // If the window is already open (e.g. a setup/login session), make
        // the switch live instead of only taking effect on the next show —
        // otherwise picking a second channel to log into does nothing until
        // the window is closed and reopened.
        orchestrator.refreshIfShowing()
    }

    @objc private func showWindowNow() {
        orchestrator.showNow(openedBy: .menu)
    }

    /// Shows the dashboard in its own native floating panel (StatsPanel) —
    /// no browser tab. The same page also stays served at
    /// `http://127.0.0.1:8765/dashboard` for anyone who prefers a browser.
    @objc private func openDashboard() {
        StatsPanel.present(stats: stats)
    }

    /// Adds or removes the `SessionStart` hook that starts the daemon with
    /// Claude Code, then rebuilds so the checkbox reflects what is actually in
    /// `settings.json` — the same "rebuild reflects reality now" pattern as
    /// `selectMode`/`selectChannel`. Turning it off means you start the daemon
    /// yourself (`/claude-maxx` does it on demand); it never stops an
    /// already-running daemon, which is what "Quit Claude Maxx" is for.
    ///
    /// An already-open Claude Code session won't pick up a hook change until
    /// it restarts, so this takes effect from the next session onward.
    @objc private func toggleStartupHook() {
        StartupHook.setEnabled(!StartupHook.isEnabled)
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

private extension Mode {
    var menuTitle: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Ask"
        case .auto: return "Auto"
        }
    }
}
