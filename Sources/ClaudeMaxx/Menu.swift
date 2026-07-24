import AppKit
import UniformTypeIdentifiers

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
            // Reading holds a list, so it gets a submenu to pick from. AppKit
            // ignores a parent item's action once it has a submenu, so
            // selecting the channel happens from inside — see readingSubmenu.
            if let reading = channel as? ReadingChannel {
                item.submenu = Self.readingSubmenu(for: reading, target: self)
            }
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
            return [Self.disabledItem("Today: \(contentMinutes)m content / \(waitMinutes)m waiting (\(daily.waits) waits)")]
        }

        var items = [Self.disabledItem("Today: \(waitMinutes)m waiting (\(daily.waits) waits)")]
        for channel in ChannelRegistry.all where channelIDsWithData.contains(channel.id) {
            let seconds = contentEvents
                .filter { $0.channel == channel.id }
                .reduce(0) { $0 + ($1.seconds ?? 0) }
            items.append(Self.disabledItem("  \(channel.displayName): \(Int(seconds / 60))m"))
        }
        return items
    }

    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Reading list

    /// The list you pick from, plus the two ways to grow it. Selecting an
    /// entry both switches to Reading and opens that entry — there is no
    /// "just switch to Reading" item, because with a list this is always the
    /// same question: read *which* one.
    ///
    /// The checkmark tracks the selected entry regardless of whether Reading
    /// is the active channel — it answers "what would this open", which is
    /// what you want to know while picking. Whether Reading is the live
    /// channel is already shown by the parent item's own checkmark.
    ///
    /// Static, and taking both the channel and the action target, so
    /// `MenuTests` can build one without constructing a `Menu` — that means
    /// an `NSStatusItem`, which aborts outright in a test process with no
    /// window-server connection. Taking the channel rather than resolving it
    /// from `ChannelRegistry` likewise keeps tests off the real user's
    /// reading list.
    static func readingSubmenu(for channel: ReadingChannel, target: AnyObject?) -> NSMenu {
        let submenu = NSMenu()
        let items = channel.urls

        if items.isEmpty {
            submenu.addItem(disabledItem("Nothing added yet"))
        } else {
            for (index, url) in items.enumerated() {
                let item = NSMenuItem(
                    title: ReadingChannel.displayTitle(for: url),
                    action: #selector(selectReadingItem(_:)),
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = index
                item.state = index == channel.currentIndex ? .on : .off
                // Titles are truncated for menu width; the tooltip is where
                // you can still see which of two similar links this is.
                item.toolTip = url.isFileURL ? url.path : url.absoluteString
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        for (title, action) in [
            ("Add Link…", #selector(addReadingLink)),
            ("Add PDF…", #selector(addReadingFile)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            submenu.addItem(item)
        }

        if let current = channel.currentURL {
            submenu.addItem(.separator())
            let remove = NSMenuItem(
                title: "Remove \(ReadingChannel.displayTitle(for: current, maxLength: 28))",
                action: #selector(removeCurrentReadingItem),
                keyEquivalent: ""
            )
            remove.target = target
            submenu.addItem(remove)
        }
        return submenu
    }

    /// Resolved through the registry rather than held as a stored property so
    /// there is exactly one `ReadingChannel` instance in the process — the
    /// same one `Orchestrator` resolves and shows. A second instance would
    /// read the same `UserDefaults` but drift on anything cached in memory.
    private var readingChannel: ReadingChannel? {
        ChannelRegistry.channel(withID: "reading") as? ReadingChannel
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

    @objc private func selectReadingItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let reading = readingChannel else { return }
        cmLog("menu: reading item \(index) selected")
        reading.select(index: index)
        switchToReading(reading)
    }

    /// Paste-in path (SPEC §8.3's "simple paste-in"), for links and for file
    /// paths people already have on the clipboard.
    @objc private func addReadingLink() {
        guard let reading = readingChannel else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com/article"

        let alert = NSAlert()
        alert.messageText = "Add to Reading"
        alert.informativeText = "Paste a link, or a path to a local file."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        guard runModal(alert, focusing: field) == .alertFirstButtonReturn else { return }
        guard reading.add(field.stringValue) != nil else {
            let failure = NSAlert()
            failure.messageText = "That isn't a link or a file path"
            failure.informativeText =
                "Try a full URL (https://example.com/article) or an absolute path "
                + "(/Users/you/paper.pdf)."
            _ = runModal(failure, focusing: nil)
            return
        }
        switchToReading(reading)
    }

    /// The other half: pick a file instead of typing where it lives. Not
    /// sandboxed, so a plain path is enough — no security-scoped bookmark to
    /// store and re-resolve on relaunch.
    @objc private func addReadingFile() {
        guard let reading = readingChannel else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to add to Reading."
        // What WebKit can actually render on its own. Anything else would
        // add to the list and then present as a download prompt or a blank
        // page, which is the failure this whole change exists to remove.
        panel.allowedContentTypes = [.pdf, .html, .plainText]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            reading.add(url)
        }
        guard !panel.urls.isEmpty else { return }
        switchToReading(reading)
    }

    @objc private func removeCurrentReadingItem() {
        guard let reading = readingChannel else { return }
        cmLog("menu: removing reading item \(reading.currentIndex)")
        reading.remove(at: reading.currentIndex)
        // Reload only if Reading is what's on screen — otherwise removing an
        // entry would yank an unrelated channel's page out from under the user.
        if settings.channel == reading.id {
            orchestrator.refreshIfShowing()
        }
    }

    /// Make Reading the live channel and show whatever it now points at. Same
    /// two steps as `selectChannel`, shared so every Reading entry point
    /// behaves identically.
    private func switchToReading(_ reading: ReadingChannel) {
        settings.channel = reading.id
        orchestrator.refreshIfShowing()
    }

    /// A `.accessory` app has no active state of its own, and a modal sheet
    /// put up from a menu action lands behind whatever the user was in unless
    /// the app is activated first. Ordering the alert's own window front as
    /// well covers the case where activation alone leaves it buried.
    private func runModal(_ alert: NSAlert, focusing field: NSView?) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        alert.window.orderFrontRegardless()
        if let field {
            alert.window.initialFirstResponder = field
        }
        return alert.runModal()
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
