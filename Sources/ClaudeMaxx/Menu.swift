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

        let loginItemTitle = LoginItem.requiresApproval
            ? "Launch at Login (approve in System Settings…)"
            : "Launch at Login"
        let loginItem = NSMenuItem(title: loginItemTitle, action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)
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
        settings.channel = id
    }

    /// If approval is pending, deep-link to System Settings instead of
    /// re-registering (which would just come back `.requiresApproval`
    /// again). Otherwise flip the OS-level login item and immediately
    /// re-query live status — same "rebuild reflects reality now" pattern
    /// as `selectMode`/`selectChannel`'s implicit rebuild on next open.
    @objc private func toggleLoginItem() {
        if LoginItem.requiresApproval {
            LoginItem.openSystemSettings()
        } else {
            LoginItem.setEnabled(!LoginItem.isEnabled)
        }
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
