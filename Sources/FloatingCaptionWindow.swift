import AppKit

final class FloatingCaptionWindow: NSObject, NSWindowDelegate {
    var onReturn: (() -> Void)?

    private let window: NSWindow
    private let textView: CaptionTextView
    private var root: ThemeRootView!
    private var scroll: NSScrollView!
    private var returnButton: NSButton!
    private var pinButton: NSButton!
    private var translucentButton: NSButton!
    private var positionButton: NSButton!
    /// 术语提示固定在字幕区下方，不随字幕滚动。
    private var termLabel: NSTextField!
    private var palette: AppPalette?

    var isVisible: Bool { window.isVisible }

    private var chosenSize: NSSize?
    private var resizingByHand = false
    private static let sizeKey = "FloatingCaptionContentSize"
    private static let pinKey = "FloatingCaptionAlwaysOnTop"
    private static let translucentKey = "FloatingCaptionTranslucent"
    /// 半透明模式下背景的不透明度，文字保持清晰不变淡。
    private static let translucentBackgroundAlpha: CGFloat = 0.55

    /// 悬浮字幕是否始终置顶。默认关闭：点击其他软件时，其他软件会显示在悬浮窗上面。
    private var alwaysOnTop = UserDefaults.standard.bool(forKey: FloatingCaptionWindow.pinKey)
    /// 悬浮字幕背景是否半透明。
    private var translucent = UserDefaults.standard.bool(forKey: FloatingCaptionWindow.translucentKey)
    /// 最新字幕显示的位置：底部、中间或上方。
    private var textPosition = CaptionPosition(rawValue:
        UserDefaults.standard.string(forKey: FloatingCaptionWindow.positionKey) ?? "") ?? .bottom
    private static let positionKey = "FloatingCaptionTextPosition"

    enum CaptionPosition: String, CaseIterable {
        case bottom, middle, upper
        var title: String {
            switch self {
            case .bottom: return "底部"
            case .middle: return "中间"
            case .upper: return "上方"
            }
        }
        /// 最新一行下方留出的可视高度比例。
        var runway: CGFloat {
            switch self {
            case .bottom: return 0
            case .middle: return 0.42
            case .upper: return 0.68
            }
        }
    }

    override init() {
        let saved = UserDefaults.standard.array(forKey: Self.sizeKey) as? [Double]
        let size: NSSize
        if let saved, saved.count == 2, saved.allSatisfy({ $0.isFinite && $0 > 0 }) {
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            size = NSSize(width: min(max(500, saved[0]), screen.width),
                          height: min(max(200, saved[1]), screen.height - 40))
        } else {
            size = NSSize(width: 580, height: 270)
        }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        textView = CaptionTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 190))
        super.init()

        window.title = "课译 · 悬浮字幕"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.hidesOnDeactivate = false
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .fullScreenDisallowsTiling]
        window.contentMinSize = NSSize(width: 500, height: 200)
        window.center()
        chosenSize = size

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
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        textView.smoothFloatingCaptions = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = NSFont.systemFont(ofSize: 18)
        scroll.documentView = textView
        textView.observeScrolling()

        returnButton = NSButton(title: "返回主界面", target: self,
                                action: #selector(returnToMain))
        returnButton.bezelStyle = .rounded

        pinButton = NSButton(title: "", target: self, action: #selector(togglePin))
        pinButton.bezelStyle = .rounded
        pinButton.toolTip = "开启后悬浮字幕始终显示在其他软件上面"

        translucentButton = NSButton(title: "", target: self, action: #selector(toggleTranslucent))
        translucentButton.bezelStyle = .rounded
        translucentButton.toolTip = "开启后悬浮字幕背景半透明，可以看到后面的内容"
        positionButton = NSButton(title: "", target: self, action: #selector(cyclePosition))
        positionButton.bezelStyle = .rounded
        positionButton.toolTip = "切换最新字幕出现的位置：底部、中间、上方"
        updateToggleTitles()

        termLabel = NSTextField(labelWithString: "")
        termLabel.lineBreakMode = .byTruncatingTail
        termLabel.maximumNumberOfLines = 1
        termLabel.cell?.wraps = false
        termLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        termLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        termLabel.isHidden = true

        for view in [scroll!, termLabel!, returnButton!, pinButton!, translucentButton!, positionButton!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: termLabel.topAnchor, constant: -8),
            termLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 4),
            termLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -4),
            termLabel.bottomAnchor.constraint(equalTo: returnButton.topAnchor, constant: -8),
            termLabel.heightAnchor.constraint(equalToConstant: 20),
            returnButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            returnButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            pinButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            pinButton.centerYAnchor.constraint(equalTo: returnButton.centerYAnchor),
            translucentButton.leadingAnchor.constraint(equalTo: pinButton.trailingAnchor, constant: 8),
            translucentButton.centerYAnchor.constraint(equalTo: returnButton.centerYAnchor),
            positionButton.leadingAnchor.constraint(equalTo: translucentButton.trailingAnchor, constant: 8),
            positionButton.centerYAnchor.constraint(equalTo: returnButton.centerYAnchor),
            positionButton.trailingAnchor.constraint(lessThanOrEqualTo: returnButton.leadingAnchor, constant: -8)
        ])
        textView.latestLineRunway = textPosition.runway
        applyTheme(AppPalette(appearance: root.effectiveAppearance, accent: AccentChoice.saved))
    }

    func applyTheme(_ palette: AppPalette) {
        self.palette = palette
        // 半透明模式只让背景变透明，字幕文字保持不透明，方便阅读。
        let alpha: CGFloat = translucent ? Self.translucentBackgroundAlpha : 1
        let background = palette.background.withAlphaComponent(alpha)
        let surface = palette.surface.withAlphaComponent(alpha)
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : palette.background
        root?.layer?.backgroundColor = background.cgColor
        scroll?.layer?.backgroundColor = surface.cgColor
        scroll?.layer?.borderColor = palette.border.cgColor
        scroll?.layer?.borderWidth = 1
        scroll?.layer?.cornerRadius = 12
        textView.applyStyle(.saved, palette: palette)
        termLabel?.textColor = palette.accent
        returnButton?.bezelColor = palette.accentSoft
        pinButton?.bezelColor = alwaysOnTop ? palette.accentSoft : nil
        translucentButton?.bezelColor = translucent ? palette.accentSoft : nil
    }

    private func updateToggleTitles() {
        pinButton?.title = alwaysOnTop ? "置顶：开" : "置顶：关"
        translucentButton?.title = translucent ? "半透明：开" : "半透明：关"
        positionButton?.title = "文字位置：" + textPosition.title
    }

    @objc private func togglePin() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: Self.pinKey)
        window.level = alwaysOnTop ? .floating : .normal
        updateToggleTitles()
        if let palette { applyTheme(palette) }
    }

    @objc private func toggleTranslucent() {
        translucent.toggle()
        UserDefaults.standard.set(translucent, forKey: Self.translucentKey)
        updateToggleTitles()
        if let palette { applyTheme(palette) }
    }

    @objc private func cyclePosition() {
        let all = CaptionPosition.allCases
        textPosition = all[((all.firstIndex(of: textPosition) ?? 0) + 1) % all.count]
        UserDefaults.standard.set(textPosition.rawValue, forKey: Self.positionKey)
        updateToggleTitles()
        textView.latestLineRunway = textPosition.runway
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }

    func update(captions: String, hint: String, fontSize: CGFloat, resetFollow: Bool = false) {
        let hasHint = !hint.isEmpty && hint != "专业词提示会显示在这里"
        let text = hasHint ? "术语  " + hint : ""
        if termLabel.stringValue != text {
            termLabel.stringValue = text
            termLabel.toolTip = hasHint ? text : nil
        }
        // 没有术语时隐藏但保留位置，避免字幕区高度来回跳动。
        termLabel.alphaValue = hasHint ? 1 : 0
        termLabel.isHidden = false
        textView.updateCaptions(captions, fontSize: fontSize)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onReturn?()
        return false
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        resizingByHand = true
    }

    func windowDidResize(_ notification: Notification) {
        guard !resizingByHand, !window.inLiveResize, let chosenSize,
              let screen = window.screen,
              window.frameRect(forContentRect: NSRect(origin: .zero, size: chosenSize)).width <= screen.visibleFrame.width,
              window.frameRect(forContentRect: NSRect(origin: .zero, size: chosenSize)).height <= screen.visibleFrame.height,
              window.contentRect(forFrameRect: window.frame).size != chosenSize else { return }
        window.setContentSize(chosenSize)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let size = window.contentRect(forFrameRect: window.frame).size
        chosenSize = size
        resizingByHand = false
        // 窗口高度变了，按新高度重新计算最新字幕的位置。
        let runway = textView.latestLineRunway
        textView.latestLineRunway = 0
        textView.latestLineRunway = runway
        UserDefaults.standard.set([Double(size.width), Double(size.height)], forKey: Self.sizeKey)
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }

    @objc private func returnToMain() { onReturn?() }
}
