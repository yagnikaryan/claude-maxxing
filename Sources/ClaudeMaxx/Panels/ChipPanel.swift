import AppKit

/// What Orchestrator needs from a chip presenter — kept as a protocol so
/// Orchestrator stays unit-testable without a real AppKit window (mirrors
/// how it already takes SettingsStore/StatsStore as injectable deps).
protocol ChipPresenting: AnyObject {
    var onWatch: (() -> Void)? { get set }
    var onSkip: (() -> Void)? { get set }
    func present()   // must be safe to call from any thread
    func dismiss()   // must be safe to call from any thread
}

/// ~260×76pt non-activating chip per SPEC §7. Top-right corner, .floating
/// level, title "Claude is working…", Watch/Skip buttons. Self-dismisses on
/// IDLE — but that's driven externally: every OFFERING→IDLE path in
/// Orchestrator already calls dismissChip(), so ChipPanel itself carries no
/// IDLE-detection timer.
final class ChipPanel: NSPanel, ChipPresenting {
    static let contentSize = NSSize(width: 260, height: 76)

    var onWatch: (() -> Void)?
    var onSkip: (() -> Void)?

    private let watchButton = NSButton(title: "Watch", target: nil, action: nil)
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

        watchButton.bezelStyle = .rounded
        watchButton.keyEquivalent = "\r"
        watchButton.target = self
        watchButton.action = #selector(watchTapped)

        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipTapped)

        let buttonRow = NSStackView(views: [watchButton, skipButton])
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

    @objc private func watchTapped() { onWatch?() }
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
