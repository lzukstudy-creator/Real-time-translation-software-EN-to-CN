import AppKit

final class ImmersiveCaptionWindow: NSObject, NSWindowDelegate {
    var onReturn: (() -> Void)?

    private let window: NSWindow
    private let textView: CaptionTextView
    private var root: ThemeRootView!
    private var scroll: NSScrollView!
    private var returnButton: NSButton!

    var isVisible: Bool { window.isVisible }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        textView = CaptionTextView(frame: NSRect(x: 0, y: 0, width: 920, height: 600))
        super.init()

        window.title = "课译 · 沉浸字幕"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 600, height: 400)

        root = ThemeRootView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in
            guard let self else { return }
            self.applyTheme(AppPalette(appearance: self.root.effectiveAppearance,
                                       accent: AccentChoice.saved))
        }
        window.contentView = root

        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        textView.animatesCaptions = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 28)
        textView.font = NSFont.systemFont(ofSize: 26)
        scroll.documentView = textView
        textView.observeScrolling()

        returnButton = NSButton(title: "退出沉浸模式", target: self,
                                action: #selector(returnToMain))
        returnButton.bezelStyle = .rounded
        returnButton.keyEquivalent = "\u{1b}"

        for view in [scroll!, returnButton!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            returnButton.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            returnButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            scroll.topAnchor.constraint(equalTo: returnButton.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])
        applyTheme(AppPalette(appearance: root.effectiveAppearance, accent: AccentChoice.saved))
    }

    func applyTheme(_ palette: AppPalette) {
        window.backgroundColor = palette.background
        root?.layer?.backgroundColor = palette.background.cgColor
        scroll?.layer?.backgroundColor = palette.surface.cgColor
        scroll?.layer?.borderColor = palette.border.cgColor
        scroll?.layer?.borderWidth = 1
        scroll?.layer?.cornerRadius = 14
        textView.applyStyle(.saved, palette: palette)
        textView.markColor = palette.accent
        returnButton?.bezelColor = palette.accentSoft
    }

    func show(on screen: NSScreen?) {
        if let frame = (screen ?? NSScreen.main)?.visibleFrame {
            window.setFrame(frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }

    func update(captions: String, fontSize: CGFloat, resetFollow: Bool = false) {
        textView.updateCaptions(captions, fontSize: max(24, fontSize + 5), resetFollow: resetFollow)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onReturn?()
        return false
    }

    @objc private func returnToMain() { onReturn?() }
}
