import AppKit

/// What Orchestrator needs from a chip presenter — kept as a protocol so
/// Orchestrator stays unit-testable without a real AppKit window (mirrors
/// how it already takes SettingsStore/StatsStore as injectable deps).
protocol ChipPresenting: AnyObject {
    var onSelect: ((String) -> Void)? { get set }   // payload: ContentChannel.id
    var onSkip: (() -> Void)? { get set }
    func present()   // must be safe to call from any thread
    func dismiss()   // must be safe to call from any thread
}

/// Non-activating chip per SPEC §7. Top-right corner, .floating level, title
/// "Claude is working…", one button per `ChannelRegistry.all` entry plus
/// Skip (M2 task 11 — v0.2's Watch/Skip becomes a channel picker). Self-
/// dismisses on IDLE — but that's driven externally: every OFFERING→IDLE
/// path in Orchestrator already calls dismissChip(), so ChipPanel itself
/// carries no IDLE-detection timer.
final class ChipPanel: NSPanel, ChipPresenting {
    /// Sized to fit one button per registered channel plus Skip, at a fixed
    /// per-button width + spacing + padding; floored at 260 (the v0.2
    /// minimum) so a future single-channel configuration doesn't shrink the
    /// chip below its original size.
    static var contentSize: NSSize {
        let buttonWidth: CGFloat = 76
        let spacing: CGFloat = 8
        let horizontalPadding: CGFloat = 12 * 2
        let buttonCount = CGFloat(ChannelRegistry.all.count + 1)   // + Skip
        let width = buttonCount * buttonWidth + (buttonCount - 1) * spacing + horizontalPadding
        return NSSize(width: max(260, width), height: 76)
    }

    var onSelect: ((String) -> Void)?
    var onSkip: (() -> Void)?

    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.nonactivatingPanel],   // borderless + never activates the app
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        title = "Claude is working…"      // accessibility/VoiceOver title; no titlebar chrome shown
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildContentView()
    }

    private func buildContentView() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Claude is working…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let channelButtons = ChannelRegistry.all.map { channel -> NSButton in
            let button = NSButton(title: channel.displayName, target: self, action: #selector(channelTapped(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(channel.id)
            return button
        }

        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipTapped)

        // No `keyEquivalent` default here — with one button per channel
        // there's no longer a single canonical "Watch" action to imply as
        // default (v0.2's Watch button had `\r`; the picker deliberately
        // doesn't privilege one channel over another).
        let buttonRow = NSStackView(views: channelButtons + [skipButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually

        let stack = NSStackView(views: [label, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        content.addSubview(background)
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        self.contentView = content
    }

    @objc private func channelTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSelect?(id)
    }
    @objc private func skipTapped() { onSkip?() }

    // MARK: ChipPresenting

    func present() {
        DispatchQueue.main.async { [weak self] in
            self?.reposition()
            self?.orderFrontRegardless()   // no makeKeyAndOrderFront: never takes key/activates app
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.orderOut(nil)
        }
    }

    private func reposition() {
        let screens = NSScreen.screens.map { WindowGeometry.ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let mainScreen = NSScreen.main ?? NSScreen.screens.first else { return }   // no displays — nothing to show
        let fallback = WindowGeometry.ScreenInfo(frame: mainScreen.frame, visibleFrame: mainScreen.visibleFrame)
        let target = WindowGeometry.targetScreen(mouseLocation: NSEvent.mouseLocation, screens: screens, fallback: fallback)
        let frame = WindowGeometry.freshFrame(desiredSize: Self.contentSize, aspectRatio: Self.contentSize, screen: target, corner: .topRight)
        setFrame(frame, display: true)
    }
}
