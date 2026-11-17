import AppKit
import AVFoundation
import Darwin
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate {
    private var window: NSWindow!
    private var themeRoot: ThemeRootView!
    private var statusCard: NSView!
    private var transcriptCard: NSView!
    private var transcriptDivider: NSView!
    private var accentPicker: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var deviceLabel: NSTextField!
    private var levelIndicator: AudioLevelView!
    private var actionButton: NSButton!
    private var pauseButton: NSButton!
    private var captionView: CaptionTextView!
    private var hintLabel: NSTextField!
    private var glossaryButton: NSButton!
    private var exportButton: NSButton!
    private var fileButton: NSButton!
    private var reviewButton: NSButton!
    private var markButton: NSButton!
    private var floatButton: NSButton!
    private var immersiveButton: NSButton!
    private var topButton: NSButton!
    private var smallerButton: NSButton!
    private var largerButton: NSButton!
    private var styleButton: NSPopUpButton!
    private var languageControl: NSSegmentedControl!
    private var captionStyleMenu: NSMenu!
    private var hintPill: NSView!
    private var hintIcon: NSImageView!
    private var controlBar: NSView!
    private var floatingWindow: FloatingCaptionWindow?
    private var immersiveWindow: ImmersiveCaptionWindow?
    private let capture = MicrophoneCapture()
    private let translator = ChineseTranslation()
    private var glossary: GlossaryStore?
    private var glossaryWindow: GlossaryWindow?
    private var archive: BilingualArchive?
    private var savedTranscriptURL: URL?
    private var worker: RecognitionWorker?
    private var sessionGeneration = 0
    private var silenceTimer: Timer?
    private static let silenceTimeout: TimeInterval = 120
    private static let audibleLevel: Float = 0.001
    private static let silenceReason = "连续 2 分钟未检测到声音"
    private var lastSoundUptime = 0.0
    private var finishing = false
    /// 暂停收声中：麦克风暂停采集，但本次会话、识别器和字幕都保留。
    private var isPaused = false
    /// 收声会话进行中（正在收声或已暂停）。
    private var sessionActive: Bool { capture.isRunning || isPaused }
    private var audioActivityCount = 0
    private var awaitingPermission = false
    private var savePanelOpen = false
    private var promptSaveOnStop = false
    private var currentStopReason = "用户停止"
    private var preferredDevice: MicrophoneChoice?
    private var englishText = ""
    private var chineseText = ""
    private var captionTimeline = CaptionTimeline()
    /// 每一句第一次出现的时间（距开始收声的秒数），用于导出 SRT 和笔记。
    private var segmentTimes: [Int: Double] = [:]
    /// 本节课出现过的术语（导出笔记用）。
    private var lectureTerms: [String: (english: String, chinese: String)] = [:]
    private var lectureTermOrder: [String] = []
    private var sessionStartedDate = Date()
    private var lectureSummary: String?
    private var submittedSegments: [Int: String] = [:]
    private var translationID = 0
    private var displayedTranslationID = 0
    private var lastTranslationSubmit = 0.0
    private var translationScheduled = false
    private var sessionStartedUptime = 0.0
    private var pendingFinalTranslationID: Int?
    private var pendingClose = false
    private var pendingQuit = false
    private var isReviewing = false
    private var englishOnly = UserDefaults.standard.bool(forKey: "EnglishOnlyCaptions")
    private var reviewEnglish = ""
    private var reviewContent = ""
    private var englishCaptions: String {
        captionTimeline.lines.isEmpty ? "Waiting for speech…" : captionTimeline.lines.map(\.english).joined(separator: "\n\n")
    }
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        englishOnly = sender.indexOfSelectedItem == 1
        UserDefaults.standard.set(englishOnly, forKey: "EnglishOnlyCaptions")
        renderCaptions()
    }
    private var liveHint = "专业词提示会显示在这里"
    private var captionFontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "TingYiCaptionFontSize")
        return saved >= 14 && saved <= 34 ? CGFloat(saved) : 19
    }()
    private var alwaysOnTop = UserDefaults.standard.bool(forKey: "TingYiAlwaysOnTop")
    private var accentChoice = AccentChoice.saved
    private var captionStyle = CaptionStyle.saved

    private var stagingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TingYi/Recording", isDirectory: true)
    }
    private var transcriptDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("课译字幕", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        preferredDevice = MicrophoneChoice.preferred()
        if let resource = Bundle.main.url(forResource: "coursepack", withExtension: "json") {
            let custom = stagingDirectory.deletingLastPathComponent().appendingPathComponent("custom-terms.json")
            glossary = try? GlossaryStore(resource: resource, customURL: custom)
        }
        let recovered = BilingualArchive.recover(staging: stagingDirectory,
                                                 destination: transcriptDirectory)
        makeWindow()
        buildMainMenu()
        translator.onResult = { [weak self] input, chinese in
            guard let self else { return }
            let current = input.session == self.sessionGeneration
            let finishingPrevious = self.finishing && input.session == self.sessionGeneration - 1
            guard (current || finishingPrevious), input.id >= self.displayedTranslationID else { return }
            self.displayedTranslationID = input.id
            if self.captionTimeline.applyTranslation(segment: input.segment,
                                                     english: input.english, chinese: chinese) {
                if self.captionTimeline.isMarked(input.segment) { self.syncMarksToArchive() }
                self.chineseText = chinese
                self.archive?.setTranslation(segment: input.segment, seconds: input.seconds,
                                             english: input.english, chinese: chinese)
                self.renderCaptions()
            }
            if let pending = self.pendingFinalTranslationID, input.id >= pending {
                self.pendingFinalTranslationID = nil
                self.finishArchive(message: "已停止收声；英中字幕已保存。")
            }
        }
        translator.onStatus = { [weak self] in self?.renderCaptions() }
        capture.onLevel = { [weak self] level in self?.levelIndicator.level = Double(level) }
        capture.onAudioActivity = { [weak self] duration, rms in
            guard let self, self.capture.isRunning else { return }
            let hadAudio = self.audioActivityCount > 0
            self.audioActivityCount += 1
            if !hadAudio && self.statusLabel.stringValue == "麦克风未送来音频" {
                self.statusLabel.stringValue = "正在识别英文"
            }
            let heardSound = rms >= Self.audibleLevel
            if heardSound { self.lastSoundUptime = ProcessInfo.processInfo.systemUptime }
            let strength = rms < 0 ? "电平格式待检查" : (heardSound ? "有声音" : "声音很小")
            let seconds = Int(duration)
            self.detailLabel.stringValue = String(format: "已收声 %02d:%02d:%02d（时:分:秒） · %@",
                                                  seconds / 3600, seconds / 60 % 60, seconds % 60, strength)
        }
        capture.onInterruption = { [weak self] in
            guard let self else { return }
            let generation = self.sessionGeneration
            let count = self.audioActivityCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.sessionGeneration == generation, !self.finishing,
                      !self.isPaused else { return }
                guard self.capture.isRunning && self.audioActivityCount > count else {
                    self.stopSession(message: "麦克风连接变化后未恢复音频，请检查输入设备。",
                                     reason: "麦克风配置变化后无音频")
                    return
                }
            }
        }
        if let latest = recovered.last {
            savedTranscriptURL = latest
            fileButton.isEnabled = true
            exportButton.isEnabled = true
            showIdle(message: "已找回 \(recovered.count) 份意外中断的字幕；点击“字幕文件”查看。")
        } else {
            showIdle(message: "点击“开始收声”以测试麦克风。")
        }
        NSApp.activate(ignoringOtherApps: true)
        writeSnapshotIfRequested()
    }

    /// 开发用：设置环境变量 TINGYI_SNAPSHOT=/路径/图.png 启动时，把主窗口渲染成图片后退出（用于检查界面）。
    /// TINGYI_SNAPSHOT_DEMO=1 时先填入示例字幕。
    private func writeSnapshotIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TINGYI_SNAPSHOT"] else { return }
        if environment["TINGYI_SNAPSHOT_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if environment["TINGYI_SNAPSHOT_DEMO"] == "1" {
            handleEnglish("Every time you make a recursive call, a new stack frame is pushed onto the call stack. If you forget the base case, the function keeps calling itself. In big O notation, a naive recursive Fibonacci is exponential.")
            for (index, chinese) in ["每次进行递归调用时，都会有一个新的栈帧被压入调用栈。", "如果忘记了基本情况，函数就会不停地调用自己。"].enumerated()
                where captionTimeline.lines.indices.contains(index) {
                _ = captionTimeline.applyTranslation(segment: index, english: captionTimeline.lines[index].english, chinese: chinese)
            }
            _ = captionTimeline.toggleLatestMark(seconds: 0)
            renderCaptions()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let view = self.window.contentView?.superview ?? self.window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            Darwin._exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture.stop()
        // The bundled ONNX Runtime crashes while destroying static C++ state on exit.
        // Active sessions finish their archive before NSApp reaches this callback.
        Darwin._exit(0)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(floatingWindow?.isVisible == true || immersiveWindow?.isVisible == true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard sessionActive || finishing else { return .terminateNow }
        pendingQuit = true
        if !finishing { stopSession(message: "已停止收声；英中字幕已保存。") }
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sessionActive || finishing else { return true }
        pendingClose = true
        if !finishing { stopSession(message: "已停止收声；英中字幕已保存。") }
        return false
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "课译"
        window.subtitle = "实时听课 · 英中对照"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.delegate = self
        window.minSize = NSSize(width: 760, height: 520)
        window.level = alwaysOnTop ? .floating : .normal
        window.center()

        themeRoot = ThemeRootView()
        themeRoot.wantsLayer = true
        themeRoot.onAppearanceChange = { [weak self] in self?.applyTheme() }
        window.contentView = themeRoot

        // 工具栏控件（图标按钮，玻璃材质由系统提供）
        languageControl = NSSegmentedControl(labels: ["英中对照", "纯英语"], trackingMode: .selectOne,
                                             target: self, action: #selector(changeLanguageSegment(_:)))
        languageControl.selectedSegment = englishOnly ? 1 : 0
        languageControl.toolTip = "字幕显示英中对照，或只显示英文"
        accentPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in AccentChoice.allCases { accentPicker.addItem(withTitle: choice.title) }
        accentPicker.selectItem(at: AccentChoice.allCases.firstIndex(of: accentChoice) ?? 0)
        glossaryButton = toolbarButton("character.book.closed", "术语表（⇧⌘T）", #selector(showGlossary))
        floatButton = toolbarButton("pip", "悬浮字幕（⇧⌘F）：小窗显示字幕，方便同时看课件", #selector(showFloating))
        immersiveButton = toolbarButton("arrow.up.left.and.arrow.down.right", "沉浸字幕（⇧⌘I）：全屏只显示字幕",
                                        #selector(showImmersive))
        let pin = StateButton(symbols: ["置顶：开": "pin.fill", "置顶：关": "pin"], iconOnly: true)
        pin.target = self
        pin.action = #selector(toggleAlwaysOnTop)
        pin.title = alwaysOnTop ? "置顶：开" : "置顶：关"
        pin.toolTip = "窗口置顶（⌥⌘T）"
        topButton = pin
        captionStyleMenu = makeCaptionStyleMenu()
        exportButton = NSButton(title: "导出字幕", target: self, action: #selector(exportTranscript))
        fileButton = NSButton(title: "字幕文件", target: self, action: #selector(revealTranscript))
        exportButton.isEnabled = false
        fileButton.isEnabled = false

        // 字幕卡片：窗口主体
        transcriptCard = NSView()
        transcriptCard.wantsLayer = true
        let preview = NSScrollView()
        preview.hasVerticalScroller = true
        preview.borderType = .noBorder
        preview.drawsBackground = false
        preview.automaticallyAdjustsContentInsets = false
        captionView = CaptionTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 220))
        captionView.animatesCaptions = true
        captionView.usesFindBar = true
        captionView.isIncrementalSearchingEnabled = true
        captionView.isEditable = false
        captionView.isSelectable = true
        captionView.drawsBackground = false
        captionView.font = NSFont.systemFont(ofSize: captionFontSize)
        captionView.textContainerInset = NSSize(width: 34, height: 26)
        captionView.string = "英文和中文实时字幕将显示在这里"
        preview.documentView = captionView
        captionView.observeScrolling()
        let translationStatusView = NSHostingView(rootView: ChineseTranslationHost(translator: translator))

        // 术语提示胶囊
        hintPill = NSView()
        hintPill.wantsLayer = true
        hintIcon = NSImageView(image: NSImage(systemSymbolName: "character.book.closed.fill",
                                              accessibilityDescription: "术语") ?? NSImage())
        hintIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        hintLabel = label("专业词提示会显示在这里", size: 12.5, weight: .medium, color: .secondaryLabelColor)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 底部玻璃控制条
        statusLabel = label("准备就绪", size: 14, weight: .semibold, color: .labelColor)
        detailLabel = label("", size: 11.5, weight: .regular, color: .secondaryLabelColor)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        deviceLabel = label("", size: 11, weight: .regular, color: .secondaryLabelColor)
        levelIndicator = AudioLevelView()
        levelIndicator.identifier = NSUserInterfaceItemIdentifier("microphoneLevel")
        levelIndicator.setAccessibilityLabel("麦克风音量")

        let capture = StateButton(symbols: ["开始收声": "mic.fill", "停止收声": "stop.fill"])
        capture.target = self
        capture.action = #selector(toggleCapture)
        capture.title = "开始收声"
        capture.controlSize = .large
        capture.identifier = NSUserInterfaceItemIdentifier("captureButton")
        capture.keyEquivalent = "\r"
        capture.fillColor = .controlAccentColor
        actionButton = capture

        let pause = StateButton(symbols: ["暂停收声": "pause.fill", "继续收声": "play.fill"])
        pause.target = self
        pause.action = #selector(togglePause)
        pause.title = "暂停收声"
        pause.identifier = NSUserInterfaceItemIdentifier("pauseButton")
        pause.toolTip = "暂时停止收声，字幕保留；可随时继续（⇧⌘R）"
        pause.isHidden = true
        pauseButton = pause

        let mark = StateButton(symbols: ["标记重点": "star", "已标记": "star.fill"])
        mark.target = self
        mark.action = #selector(toggleMark)
        mark.title = "标记重点"
        mark.toolTip = "把老师正在讲的这一句标为重点（⌘B），保存的字幕里会单独列出"
        markButton = mark

        let review = StateButton(symbols: ["回看": "clock.arrow.circlepath", "回到实时": "dot.radiowaves.left.and.right"])
        review.target = self
        review.action = #selector(toggleReview)
        review.title = "回看"
        review.toolTip = "冻结画面查看之前的字幕，后台继续收声（⌘L）"
        reviewButton = review

        smallerButton = NSButton(title: "A−", target: self, action: #selector(decreaseFont))
        largerButton = NSButton(title: "A+", target: self, action: #selector(increaseFont))
        styleButton = NSPopUpButton(frame: .zero, pullsDown: true)

        let statusStack = NSStackView(views: [statusLabel!, detailLabel!])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 1
        statusStack.setHuggingPriority(.defaultLow, for: .horizontal)
        let tools = NSStackView(views: [pause, mark, review])
        tools.orientation = .horizontal
        tools.spacing = 8
        let bar = NSStackView(views: [capture, statusStack, levelIndicator!, tools, translationStatusView])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 16
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 14)
        bar.setCustomSpacing(22, after: levelIndicator)
        // 控制条：圆角卡片，控件放在里面。
        let glass = NSView()
        glass.wantsLayer = true
        controlBar = glass
        bar.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: glass.topAnchor),
            bar.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: glass.trailingAnchor)
        ])

        for view in [transcriptCard!, hintPill!, glass] {
            view.translatesAutoresizingMaskIntoConstraints = false
            themeRoot.addSubview(view)
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        transcriptCard.addSubview(preview)
        translationStatusView.translatesAutoresizingMaskIntoConstraints = false
        for view in [hintIcon!, hintLabel!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            hintPill.addSubview(view)
        }
        for view in [capture, pause, mark, review] { view.translatesAutoresizingMaskIntoConstraints = false }
        let top = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? themeRoot.topAnchor
        NSLayoutConstraint.activate([
            transcriptCard.topAnchor.constraint(equalTo: top, constant: 10),
            transcriptCard.leadingAnchor.constraint(equalTo: themeRoot.leadingAnchor, constant: 22),
            transcriptCard.trailingAnchor.constraint(equalTo: themeRoot.trailingAnchor, constant: -22),
            transcriptCard.bottomAnchor.constraint(equalTo: hintPill.topAnchor, constant: -12),
            preview.topAnchor.constraint(equalTo: transcriptCard.topAnchor, constant: 1),
            preview.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor, constant: 1),
            preview.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor, constant: -1),
            preview.bottomAnchor.constraint(equalTo: transcriptCard.bottomAnchor, constant: -1),
            translationStatusView.widthAnchor.constraint(equalToConstant: 150),
            translationStatusView.heightAnchor.constraint(equalToConstant: 30),

            hintPill.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor),
            hintPill.trailingAnchor.constraint(lessThanOrEqualTo: transcriptCard.trailingAnchor),
            hintPill.heightAnchor.constraint(equalToConstant: 30),
            hintPill.bottomAnchor.constraint(equalTo: glass.topAnchor, constant: -12),
            hintIcon.leadingAnchor.constraint(equalTo: hintPill.leadingAnchor, constant: 12),
            hintIcon.centerYAnchor.constraint(equalTo: hintPill.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: hintIcon.trailingAnchor, constant: 7),
            hintLabel.trailingAnchor.constraint(equalTo: hintPill.trailingAnchor, constant: -14),
            hintLabel.centerYAnchor.constraint(equalTo: hintPill.centerYAnchor),

            glass.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: themeRoot.bottomAnchor, constant: -18),
            capture.heightAnchor.constraint(equalToConstant: 40),
            capture.widthAnchor.constraint(greaterThanOrEqualToConstant: 128),
            levelIndicator.widthAnchor.constraint(equalToConstant: 76),
            levelIndicator.heightAnchor.constraint(equalToConstant: 28)
        ])

        let toolbar = NSToolbar(identifier: "TingYiMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        applyTheme()
        window.makeKeyAndOrderFront(nil)
    }

    private func toolbarButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: self, action: action)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    @objc private func changeLanguageSegment(_ sender: NSSegmentedControl) {
        englishOnly = sender.selectedSegment == 1
        UserDefaults.standard.set(englishOnly, forKey: "EnglishOnlyCaptions")
        renderCaptions()
    }

    // MARK: 工具栏

    private enum ToolbarID {
        static let language = NSToolbarItem.Identifier("language")
        static let glossary = NSToolbarItem.Identifier("glossary")
        static let floating = NSToolbarItem.Identifier("floating")
        static let immersive = NSToolbarItem.Identifier("immersive")
        static let pin = NSToolbarItem.Identifier("pin")
        static let style = NSToolbarItem.Identifier("style")
        static let export = NSToolbarItem.Identifier("export")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.language, .space, ToolbarID.glossary, ToolbarID.floating,
         ToolbarID.immersive, ToolbarID.pin, .space, ToolbarID.style, ToolbarID.export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func viewItem(_ view: NSView, _ label: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = view
            item.label = label
            item.toolTip = view.toolTip
            return item
        }
        func menuItem(_ symbol: String, _ label: String, _ menu: NSMenu) -> NSToolbarItem {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.menu = menu
            item.showsIndicator = true
            return item
        }
        switch identifier {
        case ToolbarID.language: return viewItem(languageControl, "字幕语言")
        case ToolbarID.glossary: return viewItem(glossaryButton, "术语表")
        case ToolbarID.floating: return viewItem(floatButton, "悬浮字幕")
        case ToolbarID.immersive: return viewItem(immersiveButton, "沉浸字幕")
        case ToolbarID.pin: return viewItem(topButton, "置顶")
        case ToolbarID.style: return menuItem("textformat.size", "字幕样式与配色", captionStyleMenu)
        case ToolbarID.export:
            let menu = NSMenu()
            for (title, action) in [("导出字幕…（TXT / 笔记 / SRT）", #selector(exportTranscript)),
                                    ("在访达中显示字幕文件", #selector(revealTranscript))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            for (title, action) in [("用 Claude 生成课后总结（使用你的订阅额度）", #selector(toggleClaudeSummary)),
                                    ("重新生成课后总结", #selector(regenerateSummary))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            return menuItem("square.and.arrow.up", "导出与总结", menu)
        default: return nil
        }
    }

    private func applyTheme() {
        guard let root = themeRoot, let window else { return }
        let palette = AppPalette(appearance: root.effectiveAppearance, accent: accentChoice)
        window.backgroundColor = palette.background
        root.layer?.backgroundColor = palette.background.cgColor
        if let card = transcriptCard?.layer {
            card.backgroundColor = palette.surface.cgColor
            card.borderColor = palette.border.withAlphaComponent(palette.dark ? 0.9 : 0.7).cgColor
            card.borderWidth = 1
            card.cornerRadius = 22
            card.cornerCurve = .continuous
            card.masksToBounds = true
        }
        if let pill = hintPill?.layer {
            pill.backgroundColor = palette.accentSoft.cgColor
            pill.cornerRadius = 15
            pill.cornerCurve = .continuous
        }
        hintIcon?.contentTintColor = palette.accent
        (actionButton as? StateButton)?.fillColor = palette.accent
        for button in [pauseButton, markButton, reviewButton] { (button as? StateButton)?.textColor = palette.text }
        statusLabel?.textColor = palette.text
        detailLabel?.textColor = palette.secondary
        deviceLabel?.textColor = palette.secondary
        hintLabel?.textColor = palette.dark ? palette.text : palette.text.withAlphaComponent(0.85)
        levelIndicator?.accentColor = palette.accent
        if let bar = controlBar?.layer {
            bar.backgroundColor = palette.surface.withAlphaComponent(palette.dark ? 0.92 : 0.96).cgColor
            bar.borderColor = palette.border.cgColor
            bar.borderWidth = 1
            bar.cornerRadius = 30
            bar.cornerCurve = .continuous
            bar.shadowColor = NSColor.black.cgColor
            bar.shadowOpacity = palette.dark ? 0.4 : 0.08
            bar.shadowRadius = 14
            bar.shadowOffset = CGSize(width: 0, height: -3)
        }
        captionView?.applyStyle(captionStyle, palette: palette)
        captionView?.markColor = palette.accent
        for (index, choice) in AccentChoice.allCases.enumerated() {
            accentPicker?.item(at: index)?.image = choice.swatch(dark: palette.dark)
        }
        for item in captionStyleMenu?.items ?? [] where item.action == #selector(selectAccentItem(_:)) {
            if let raw = item.representedObject as? String, let choice = AccentChoice(rawValue: raw) {
                item.image = choice.swatch(dark: palette.dark)
                item.state = choice == accentChoice ? .on : .off
            }
        }
        refreshCaptionStyleMenu(palette: palette)
        floatingWindow?.applyTheme(palette)
        immersiveWindow?.applyTheme(palette)
        glossaryWindow?.applyTheme(palette)
    }

    @objc private func selectAccent(_ sender: NSPopUpButton) {
        guard AccentChoice.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        accentChoice = AccentChoice.allCases[sender.indexOfSelectedItem]
        UserDefaults.standard.set(accentChoice.rawValue, forKey: AccentChoice.preferenceKey)
        applyTheme()
    }

    // MARK: 字幕样式（字体与颜色）

    private func makeCaptionStyleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem.sectionHeader(title: "字号"))
        for (title, action, key) in [("放大字幕", #selector(increaseFont), "="), ("缩小字幕", #selector(decreaseFont), "-")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "字体"))
        for choice in CaptionFontChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectCaptionFont(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.attributedTitle = NSAttributedString(string: choice.title, attributes: [
                .font: choice.font(ofSize: 13, weight: .regular)
            ])
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "字幕颜色"))
        for choice in CaptionColorChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectCaptionColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "界面点缀色"))
        for choice in AccentChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectAccentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectAccentItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = AccentChoice(rawValue: raw) else { return }
        accentChoice = choice
        accentPicker?.selectItem(at: AccentChoice.allCases.firstIndex(of: choice) ?? 0)
        UserDefaults.standard.set(choice.rawValue, forKey: AccentChoice.preferenceKey)
        applyTheme()
    }

    private func refreshCaptionStyleMenu(palette: AppPalette) {
        guard let menu = captionStyleMenu else { return }
        for item in menu.items {
            guard let raw = item.representedObject as? String else { continue }
            if item.action == #selector(selectCaptionFont(_:)) {
                item.state = raw == captionStyle.font.rawValue ? .on : .off
            } else if let choice = CaptionColorChoice(rawValue: raw) {
                item.state = choice == captionStyle.color ? .on : .off
                item.image = choice.swatch(palette: palette)
            }
        }
    }

    @objc private func selectCaptionFont(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = CaptionFontChoice(rawValue: raw) else { return }
        captionStyle.font = choice
        UserDefaults.standard.set(choice.rawValue, forKey: CaptionFontChoice.preferenceKey)
        applyTheme()
    }

    @objc private func selectCaptionColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = CaptionColorChoice(rawValue: raw) else { return }
        if choice == .custom {
            let panel = NSColorPanel.shared
            panel.showsAlpha = false
            panel.color = CaptionColorChoice.savedCustomColor
            panel.setTarget(self)
            panel.setAction(#selector(customCaptionColorChanged(_:)))
            panel.title = "字幕颜色"
            panel.orderFront(nil)
        }
        captionStyle.color = choice
        UserDefaults.standard.set(choice.rawValue, forKey: CaptionColorChoice.preferenceKey)
        applyTheme()
    }

    @objc private func customCaptionColorChanged(_ sender: NSColorPanel) {
        CaptionColorChoice.saveCustom(sender.color)
        captionStyle.color = .custom
        UserDefaults.standard.set(CaptionColorChoice.custom.rawValue, forKey: CaptionColorChoice.preferenceKey)
        applyTheme()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = NSFont.systemFont(ofSize: size, weight: weight)
        view.textColor = color
        return view
    }

    @objc private func toggleCapture() {
        guard !finishing, !savePanelOpen else { return }
        if sessionActive {
            promptSaveOnStop = true
            stopSession(message: "已停止收声；本次英中字幕保留在窗口中。")
            return
        }
        requestCapturePermission()
    }

    @objc private func togglePause() {
        guard sessionActive, !finishing, worker != nil else { return }
        if isPaused {
            do {
                try capture.resume()
            } catch {
                stopSession(message: "继续收声失败：\(error.localizedDescription)",
                            reason: "继续收声失败")
                return
            }
            isPaused = false
            pauseButton.title = "暂停收声"
            pauseButton.toolTip = "暂时停止收声，字幕保留；可随时继续"
            statusLabel.stringValue = isReviewing ? "回看中 · 后台继续收声" : "正在识别英文"
            detailLabel.stringValue = "已继续收声，字幕将接着之前的内容显示。"
            startSilenceTimer(generation: sessionGeneration)
        } else {
            capture.pause()
            isPaused = true
            // 暂停期间不计入自动停止的静音时长。
            silenceTimer?.invalidate()
            silenceTimer = nil
            levelIndicator.level = 0
            pauseButton.title = "继续收声"
            pauseButton.toolTip = "接着之前的字幕继续收声"
            statusLabel.stringValue = isReviewing ? "回看中 · 已暂停收声" : "已暂停收声"
            detailLabel.stringValue = "字幕已保留；点击“继续收声”接着识别，点击“停止收声”结束并保存。"
            // 把已识别但尚未翻译的内容先翻译出来。
            submitTranslation()
        }
    }

    private func requestCapturePermission() {
        guard !awaitingPermission else { return }
        awaitingPermission = true
        actionButton.isEnabled = false
        statusLabel.stringValue = "正在检查麦克风权限…"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.awaitingPermission = false
                self.actionButton.isEnabled = true
                guard granted else {
                    self.showIdle(message: "麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许“课译”。")
                    return
                }
                self.startCapture()
            }
        }
    }

    private func startCapture() {
        do {
            try capture.start(preferredDevice: preferredDevice)
            guard let inputFormat = capture.inputFormat,
                  let model = Bundle.main.resourceURL?.appendingPathComponent("EnglishModel") else {
                throw RecognitionError.missingModel
            }
            let transcript = try BilingualArchive(stagingDirectory: stagingDirectory,
                                                  destinationDirectory: transcriptDirectory)
            transcript.onError = { [weak self] error in
                DispatchQueue.main.async { [weak self] in
                    self?.statusLabel.stringValue = "字幕自动保存失败"
                    self?.detailLabel.stringValue = error.localizedDescription
                }
            }
            archive = transcript
            savedTranscriptURL = transcript.destinationURL
            exportButton.isEnabled = true
            fileButton.isEnabled = true
            sessionGeneration += 1
            let generation = sessionGeneration
            audioActivityCount = 0
            sessionStartedUptime = ProcessInfo.processInfo.systemUptime
            englishText = ""
            chineseText = ""
            captionTimeline = CaptionTimeline()
            segmentTimes = [:]
            lectureTerms = [:]
            lectureTermOrder = []
            sessionStartedDate = Date()
            markButton?.title = "标记重点"
            lectureSummary = nil
            submittedSegments = [:]
            lastTranslationSubmit = 0
            translationScheduled = false
            displayedTranslationID = translationID
            isReviewing = false
            reviewButton.title = "回看"
            liveHint = glossary == nil ? "术语表未能加载" : "专业词提示会显示在这里"
            hintLabel.stringValue = liveHint
            renderCaptions(resetFollow: true)
            translator.prepare()
            statusLabel.stringValue = "正在准备英文识别"
            detailLabel.stringValue = "麦克风已连接，模型加载完成后开始显示字幕。"
            actionButton.title = "停止收声"
            isPaused = false
            pauseButton.title = "暂停收声"
            pauseButton.isHidden = false
            pauseButton.isEnabled = false
            let hotwords = glossary?.hotwords ?? []
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    // 二次精确识别仍在调优：评测证明比实时识别更准之前默认关闭。
                    let refineModel = UserDefaults.standard.bool(forKey: "TingYiTwoPassRefine")
                        ? Bundle.main.url(forResource: "RefineModel", withExtension: nil) : nil
                    let ready = try RecognitionWorker(model: model, inputFormat: inputFormat,
                                                      hotwords: hotwords, refineModel: refineModel)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionGeneration == generation, self.capture.isRunning else { return }
                        self.worker = ready
                        self.pauseButton.isEnabled = true
                        self.startSilenceTimer(generation: generation)
                        ready.onText = { [weak self] text in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sessionGeneration == generation else { return }
                                if text.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")) != nil {
                                    self.lastSoundUptime = ProcessInfo.processInfo.systemUptime
                                }
                                self.handleEnglish(text)
                            }
                        }
                        ready.onError = { [weak self] message in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sessionGeneration == generation else { return }
                                self.stopSession(message: message, reason: "识别任务错误")
                            }
                        }
                        ready.onWarning = { [weak self] message in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.sessionGeneration == generation,
                                      self.capture.isRunning else { return }
                                NSLog("课译识别状态：%@", message)
                                self.statusLabel.stringValue = message.contains("已恢复") ?
                                    "正在识别英文" : "识别暂时延迟"
                                self.detailLabel.stringValue = message
                            }
                        }
                        self.capture.onBuffer = { buffer in ready.submit(buffer) }
                        self.statusLabel.stringValue = "正在识别英文"
                        self.detailLabel.stringValue = "正在等待麦克风音频…"
                        if !ready.enhanced, !hotwords.isEmpty {
                            self.liveHint = "专业词识别增强未启用；普通英文识别仍可使用。"
                            if !self.isReviewing { self.hintLabel.stringValue = self.liveHint }
                        }
                        self.renderCaptions()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard let self, self.sessionGeneration == generation,
                                  self.capture.isRunning, self.audioActivityCount == 0 else { return }
                            self.statusLabel.stringValue = "麦克风未送来音频"
                            self.detailLabel.stringValue = "收声仍开启；请检查输入设备和麦克风权限。"
                        }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.stopSession(message: "识别模型启动失败：\(error.localizedDescription)",
                                         reason: "识别模型启动失败")
                    }
                }
            }
        } catch {
            capture.stop()
            archive?.finish(reason: "启动失败") { _ in }
            archive = nil
            exportButton.isEnabled = savedTranscriptURL != nil
            showIdle(message: "启动失败：\(error.localizedDescription)")
        }
    }

    private func startSilenceTimer(generation: Int) {
        silenceTimer?.invalidate()
        lastSoundUptime = ProcessInfo.processInfo.systemUptime
        scheduleSilenceCheck(generation: generation, after: Self.silenceTimeout)
    }

    private func scheduleSilenceCheck(generation: Int, after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.sessionGeneration == generation,
                  self.capture.isRunning, !self.isPaused, !self.finishing else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.lastSoundUptime
            let remaining = Self.silenceTimeout - elapsed
            if remaining > 0 {
                self.scheduleSilenceCheck(generation: generation, after: remaining)
                return
            }
            self.stopSession(message: Self.silenceReason + "，已自动停止并保存字幕。",
                             reason: Self.silenceReason)
        }
        silenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSession(message: String, reason: String = "用户停止") {
        guard !finishing else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        currentStopReason = reason
        if reason != "用户停止" { NSLog("课译收声中断：%@", reason) }
        sessionGeneration += 1
        let generation = sessionGeneration
        capture.stop()
        isPaused = false
        pauseButton.isHidden = true
        pauseButton.title = "暂停收声"
        finishing = true
        actionButton.isEnabled = false
        statusLabel.stringValue = "正在完成字幕并保存…"
        if let worker {
            self.worker = nil
            worker.finish { [weak self] text in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    if !text.isEmpty {
                        // 二次精确识别会修改较早的句子，最终文本不一定以当前字幕开头，同样要显示。
                        if text.hasPrefix(self.englishText) || worker.refining {
                            self.handleEnglish(text)
                        } else {
                            self.archive?.setEnglish(text)
                        }
                        self.submitTranslation()
                    }
                    self.waitForFinalTranslation(message: message, generation: generation)
                }
            }
        } else {
            waitForFinalTranslation(message: message, generation: generation)
        }
    }

    private func waitForFinalTranslation(message: String, generation: Int) {
        guard translator.ready, translationID > displayedTranslationID else {
            finishArchive(message: message)
            return
        }
        let target = translationID
        pendingFinalTranslationID = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.sessionGeneration == generation,
                  self.pendingFinalTranslationID == target else { return }
            self.pendingFinalTranslationID = nil
            self.finishArchive(message: message)
        }
    }

    private func finishArchive(message: String) {
        guard finishing else { return }
        pendingFinalTranslationID = nil
        lectureSummary = LectureSummary.make(lines: summaryLines, terms: lectureTermList)
        if ClaudeSummarizer.enabled, lectureSummary != nil { requestClaudeSummary(replacing: lectureSummary) }
        if isReviewing {
            isReviewing = false
            reviewButton.title = "回看"
            hintLabel.stringValue = liveHint
        }
        if lectureSummary != nil { captionView.resumeFollowing() }
        renderCaptions()
        guard let archive else {
            completeStop(message: message, error: nil)
            return
        }
        if let lectureSummary { archive.setSummary(lectureSummary) }
        self.archive = nil
        archive.finish(reason: currentStopReason) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.savedTranscriptURL = url
                    self.completeStop(message: message, error: nil)
                case .failure(let error):
                    self.savedTranscriptURL = archive.stagingURL
                    self.completeStop(message: message, error: error)
                }
            }
        }
    }

    private func completeStop(message: String, error: Error?) {
        finishing = false
        actionButton.isEnabled = !savePanelOpen
        exportButton.isEnabled = savedTranscriptURL != nil
        fileButton.isEnabled = savedTranscriptURL != nil
        showIdle(message: error == nil ? message : "字幕保存失败：\(error!.localizedDescription)")
        if error != nil { statusLabel.stringValue = "字幕保存失败" }
        else if currentStopReason == Self.silenceReason {
            statusLabel.stringValue = "已自动停止"
            detailLabel.stringValue = Self.silenceReason + "，字幕已自动保存。"
            showMainWindow()
        } else if currentStopReason != "用户停止" {
            statusLabel.stringValue = "收声中断"
            showMainWindow()
        }
        if pendingQuit {
            promptSaveOnStop = false
            pendingQuit = false
            NSApp.terminate(nil)
        } else if pendingClose {
            promptSaveOnStop = false
            pendingClose = false
            window.performClose(nil)
        } else if promptSaveOnStop {
            promptSaveOnStop = false
            showFinalSavePanel()
        }
    }

    private func showFinalSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = transcriptDirectory
        let basename = savedTranscriptURL?.deletingPathExtension().lastPathComponent ?? "课译字幕"
        panel.nameFieldStringValue = "\(basename)-英中对照.txt"
        panel.message = "保存本次逐行英中翻译文本。取消时仍保留自动保存的副本。"
        savePanelOpen = true
        actionButton.isEnabled = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.savePanelOpen = false
            self.actionButton.isEnabled = true
            guard response == .OK, let url = panel.url else { return }
            let captions = self.captionTimeline.lines.isEmpty ? "（暂无字幕）" : self.fullCaptionText
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    try Data((captions + "\n").utf8).write(to: url, options: .atomic)
                    DispatchQueue.main.async { [weak self] in
                        self?.savedTranscriptURL = url
                        self?.fileButton.isEnabled = true
                        self?.detailLabel.stringValue = "翻译文本已保存：\(url.lastPathComponent)"
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.showMessage("保存失败", error.localizedDescription)
                    }
                }
            }
        }
    }

    private func showIdle(message: String) {
        statusLabel.stringValue = "准备就绪"
        detailLabel.stringValue = message
        deviceLabel.stringValue = preferredDevice.map { "输入设备：\($0.name)（内置）" } ?? "输入设备：系统默认麦克风"
        levelIndicator.toolTip = deviceLabel.stringValue
        actionButton.title = "开始收声"
        pauseButton.isHidden = true
        levelIndicator.level = 0
    }

    private func handleEnglish(_ text: String) {
        englishText = text
        captionTimeline.updateEnglish(text)
        let now = sessionStartedUptime > 0 ? max(0, ProcessInfo.processInfo.systemUptime - sessionStartedUptime) : 0
        for index in captionTimeline.lines.indices where segmentTimes[index] == nil { segmentTimes[index] = now }
        archive?.setEnglish(text)
        let recent = String(text.suffix(450))
        let context = String(text.suffix(1400))
        let hints = glossary?.suggestions(in: recent, context: context) ?? []
        for hint in hints where lectureTerms[hint.english.lowercased()] == nil {
            lectureTerms[hint.english.lowercased()] = (hint.english, hint.chinese)
            lectureTermOrder.append(hint.english.lowercased())
        }
        liveHint = hints.isEmpty ? "专业词提示会显示在这里" :
            hints.map { "\($0.english) → \($0.chinese)" }.joined(separator: "    ·    ")
        if !isReviewing { hintLabel.stringValue = liveHint }
        renderCaptions()
        scheduleTranslation()
    }

    private func renderCaptions(resetFollow: Bool = false) {
        guard captionView != nil else { return }
        let live = englishOnly ? englishCaptions : fullCaptionText
        let content = isReviewing ? (englishOnly ? reviewEnglish : reviewContent) : live
        hintPill?.isHidden = englishOnly
        captionView.updateCaptions(content, fontSize: captionFontSize,
                                   allowFollow: !isReviewing, resetFollow: resetFollow)
        floatingWindow?.update(captions: live,
                               hint: englishOnly ? "" : liveHint, fontSize: captionFontSize,
                               resetFollow: resetFollow)
        immersiveWindow?.update(captions: live, fontSize: captionFontSize,
                                resetFollow: resetFollow)
    }

    private var fullCaptionText: String {
        let captions = captionTimeline.displayText
        guard let lectureSummary else { return captions }
        return captions + "\n\n────────\n\n" + lectureSummary
    }

    private func scheduleTranslation() {
        guard !captionTimeline.lines.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = 1.4
        if now - lastTranslationSubmit >= interval {
            submitTranslation()
            return
        }
        guard !translationScheduled else { return }
        translationScheduled = true
        let generation = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + interval - (now - lastTranslationSubmit)) { [weak self] in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }
            self.translationScheduled = false
            self.submitTranslation()
        }
    }

    private func submitTranslation() {
        let pending = captionTimeline.lines.enumerated().filter { index, line in
            line.english.count >= 4 && submittedSegments[index] != line.english
        }
        guard !pending.isEmpty else { return }
        lastTranslationSubmit = ProcessInfo.processInfo.systemUptime
        let seconds = max(0, lastTranslationSubmit - sessionStartedUptime)
        for (segment, line) in pending {
            submittedSegments[segment] = line.english
            translationID += 1
            translator.submit(TranslationInput(id: translationID, session: sessionGeneration,
                                               segment: segment, seconds: seconds,
                                               english: line.english))
        }
    }

    @objc private func showGlossary() {
        guard let glossary else {
            showMessage("术语表尚未载入", "请重新安装包含课程词表的完整课译 App。")
            return
        }
        if glossaryWindow == nil {
            let window = GlossaryWindow(store: glossary)
            window.onChange = { [weak self] in
                guard let self else { return }
                self.handleEnglish(self.englishText)
            }
            glossaryWindow = window
        }
        glossaryWindow?.show()
    }

    private enum ExportFormat: Int, CaseIterable {
        case text, markdown, srt
        var title: String {
            switch self {
            case .text: return "英中对照全文（TXT）"
            case .markdown: return "学习笔记（Markdown：重点、术语、总结、全文）"
            case .srt: return "字幕文件（SRT，可配合课堂录像）"
            }
        }
        var fileExtension: String {
            switch self { case .text: return "txt"; case .markdown: return "md"; case .srt: return "srt" }
        }
    }

    private var exportLines: [LectureExport.Line] {
        captionTimeline.lines.enumerated().map { index, line in
            LectureExport.Line(start: segmentTimes[index] ?? 0, english: line.english,
                               chinese: line.chinese, marked: captionTimeline.isMarked(index))
        }
    }

    @objc private func exportTranscript() {
        guard archive != nil || savedTranscriptURL != nil else { return }
        let panel = NSSavePanel()
        let base = (savedTranscriptURL ?? archive?.stagingURL)?.deletingPathExtension().lastPathComponent ?? "课译字幕"
        // 只有本次打开 App 后收声的内容才有逐句时间，可导出笔记和 SRT。
        let formats: [ExportFormat] = captionTimeline.lines.isEmpty ? [.text] : ExportFormat.allCases
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        formats.forEach { picker.addItem(withTitle: $0.title) }
        let remembered = UserDefaults.standard.integer(forKey: "TingYiExportFormat")
        picker.selectItem(at: formats.firstIndex { $0.rawValue == remembered } ?? 0)
        let label = NSTextField(labelWithString: "格式：")
        let accessory = NSStackView(views: [label, picker])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        func format() -> ExportFormat { formats[max(0, picker.indexOfSelectedItem)] }
        func applyExtension() {
            panel.allowedContentTypes = [UTType(filenameExtension: format().fileExtension) ?? .plainText]
            panel.nameFieldStringValue = base + "." + format().fileExtension
        }
        applyExtension()
        let changeTarget = ClosureTarget { applyExtension() }
        picker.target = changeTarget
        picker.action = #selector(ClosureTarget.run)
        panel.begin { [weak self] response in
            withExtendedLifetime(changeTarget) {}
            guard let self, response == .OK, let target = panel.url else { return }
            let chosen = format()
            UserDefaults.standard.set(chosen.rawValue, forKey: "TingYiExportFormat")
            switch chosen {
            case .markdown, .srt:
                let lines = self.exportLines
                let end = self.sessionActive ? ProcessInfo.processInfo.systemUptime - self.sessionStartedUptime
                    : (lines.last.map { $0.start + 6 } ?? 0)
                let terms = self.lectureTermOrder.compactMap { self.lectureTerms[$0] }
                let content = chosen == .srt ? LectureExport.srt(lines, end: end)
                    : LectureExport.markdown(lines, date: self.sessionStartedDate, terms: terms,
                                             summary: self.lectureSummary)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    do { try Data(content.utf8).write(to: target, options: .atomic) }
                    catch { DispatchQueue.main.async { self?.showMessage("导出失败", error.localizedDescription) } }
                }
            case .text:
                self.exportArchiveText(to: target)
            }
        }
    }

    private func exportArchiveText(to target: URL) {
        if let archive {
            archive.export(to: target) { [weak self] result in
                if case .failure(let error) = result {
                    DispatchQueue.main.async { self?.showMessage("导出失败", error.localizedDescription) }
                }
            }
        } else if let source = savedTranscriptURL {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    if source.standardizedFileURL != target.standardizedFileURL {
                        try Data(contentsOf: source).write(to: target, options: .atomic)
                    }
                } catch {
                    DispatchQueue.main.async { self?.showMessage("导出失败", error.localizedDescription) }
                }
            }
        }
    }

    @objc private func revealTranscript() {
        guard let savedTranscriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedTranscriptURL])
    }

    @objc private func toggleReview() {
        if isReviewing {
            isReviewing = false
            reviewButton.title = "回看"
            hintLabel.stringValue = liveHint
            statusLabel.stringValue = isPaused ? "已暂停收声" : (capture.isRunning ? "正在识别英文" : "准备就绪")
            captionView.resumeFollowing()
        } else {
            reviewEnglish = englishCaptions
            reviewContent = fullCaptionText
            isReviewing = true
            reviewButton.title = "回到实时"
            statusLabel.stringValue = isPaused ? "回看中 · 已暂停收声" :
                (capture.isRunning ? "回看中 · 后台继续收声" : "回看中")
        }
        renderCaptions()
    }

    // MARK: 重点标记

    @objc private func toggleMark() {
        guard !captionTimeline.lines.isEmpty else {
            NSSound.beep()
            return
        }
        let seconds = captionTimeline.lines.indices.last.flatMap { segmentTimes[$0] } ?? 0
        let marked = captionTimeline.toggleLatestMark(seconds: seconds)
        detailLabel.stringValue = marked ? "已把当前这句标为重点；再按一次 ⌘B 取消。" : "已取消重点标记。"
        markButton.title = marked ? "已标记" : "标记重点"
        if marked {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.markButton.title = "标记重点"
            }
        }
        syncMarksToArchive()
        renderCaptions()
    }

    private func syncMarksToArchive() {
        let lines = captionTimeline.lines
        let marked = captionTimeline.marks.sorted { $0.key < $1.key }
            .filter { lines.indices.contains($0.key) }
            .map { (seconds: $0.value, english: lines[$0.key].english, chinese: lines[$0.key].chinese) }
        archive?.setMarks(marked)
    }

    // MARK: 菜单栏与快捷键

    private func buildMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target ?? self
            return item
        }
        func responder(_ title: String, _ action: Selector, _ key: String,
                       _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item  // 交给当前焦点（文字视图、窗口）处理
        }
        submenu("课译", [
            item("关于课译", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            .separator(),
            item("隐藏课译", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            .separator(),
            item("退出课译", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        ])
        submenu("文件", [
            item("导出字幕…", #selector(exportTranscript), "e", [.command, .shift]),
            item("在访达中显示字幕文件", #selector(revealTranscript), "o", [.command, .shift]),
            .separator(),
            item("用 Claude 生成课后总结（使用你的 Claude 订阅额度）", #selector(toggleClaudeSummary)),
            item("重新生成课后总结", #selector(regenerateSummary)),
            .separator(),
            responder("关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        ])
        submenu("编辑", [
            responder("拷贝", #selector(NSText.copy(_:)), "c"),
            responder("全选", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("查找…", #selector(showFind), "f"),
            item("查找下一个", #selector(findNext), "g"),
            item("查找上一个", #selector(findPrevious), "g", [.command, .shift])
        ])
        submenu("收声", [
            item("开始收声", #selector(toggleCapture), "r"),
            item("暂停收声", #selector(togglePause), "r", [.command, .shift]),
            .separator(),
            item("标记重点", #selector(toggleMark), "b"),
            item("回看", #selector(toggleReview), "l"),
            .separator(),
            item("术语表", #selector(showGlossary), "t", [.command, .shift])
        ])
        submenu("显示", [
            item("放大字幕", #selector(increaseFont), "="),
            item("缩小字幕", #selector(decreaseFont), "-"),
            .separator(),
            item("悬浮字幕", #selector(showFloating), "f", [.command, .shift]),
            item("沉浸字幕", #selector(showImmersive), "i", [.command, .shift]),
            item("返回主界面", #selector(returnToMainWindow), "0"),
            item("窗口置顶", #selector(toggleAlwaysOnTop), "t", [.command, .option])
        ])
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(responder("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        let windowHolder = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowHolder.submenu = windowMenu
        main.addItem(windowHolder)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func returnToMainWindow() { showMainWindow() }

    // MARK: 课后总结

    private var claudeSummaryRunning = false

    private var summaryLines: [LectureSummary.Line] {
        captionTimeline.lines.enumerated().map { index, line in
            LectureSummary.Line(start: segmentTimes[index] ?? 0, english: line.english,
                                chinese: line.chinese, marked: captionTimeline.isMarked(index))
        }
    }

    private var lectureTermList: [(english: String, chinese: String)] {
        lectureTermOrder.compactMap { lectureTerms[$0] }
    }

    @objc private func toggleClaudeSummary() {
        let enable = !ClaudeSummarizer.enabled
        if enable, ClaudeSummarizer.locate() == nil {
            showMessage("没有找到 Claude Code",
                        "这个功能通过你电脑上的 Claude Code 生成总结，使用你的 Claude 订阅额度，不额外收费。请先安装 Claude 桌面版或 Claude Code。")
            return
        }
        UserDefaults.standard.set(enable, forKey: ClaudeSummarizer.preferenceKey)
        detailLabel.stringValue = enable ? "已开启：停止收声后用 Claude 生成课后总结（使用你的订阅额度）。"
            : "已关闭 Claude 总结，改用本机总结。"
    }

    @objc private func regenerateSummary() {
        guard !captionTimeline.lines.isEmpty else { return }
        let previous = lectureSummary
        lectureSummary = LectureSummary.make(lines: summaryLines, terms: lectureTermList)
        if let previous, let lectureSummary { replaceSummaryInSavedFile(previous, with: lectureSummary) }
        renderCaptions()
        captionView.resumeFollowing()
        if ClaudeSummarizer.enabled { requestClaudeSummary(replacing: lectureSummary) }
    }

    private func requestClaudeSummary(replacing local: String?) {
        guard !claudeSummaryRunning else { return }
        claudeSummaryRunning = true
        let generation = sessionGeneration
        detailLabel.stringValue = "正在用 Claude 生成课后总结…（使用你的 Claude 订阅额度）"
        ClaudeSummarizer.summarize(lines: summaryLines, terms: lectureTermList) { [weak self] result in
            guard let self else { return }
            self.claudeSummaryRunning = false
            guard self.sessionGeneration == generation, !self.sessionActive else { return }
            switch result {
            case .success(let text):
                let old = self.lectureSummary
                self.lectureSummary = text
                if let old { self.replaceSummaryInSavedFile(old, with: text) }
                self.renderCaptions()
                self.captionView.resumeFollowing()
                self.detailLabel.stringValue = "Claude 课后总结已生成，并写入保存的字幕文件。"
            case .failure(ClaudeSummarizer.Failure.notLoggedIn):
                self.detailLabel.stringValue = "Claude Code 未登录，已使用本机总结。"
                self.offerClaudeLogin()
            case .failure(let error):
                self.detailLabel.stringValue = "Claude 总结未完成（\(error.localizedDescription)），已使用本机总结。"
            }
        }
    }

    /// 自动保存的字幕文件已经写入了本机总结，换成新的总结。
    private func replaceSummaryInSavedFile(_ old: String, with new: String) {
        guard let url = savedTranscriptURL, old != new else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(old) else { return }
            try? Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: url, options: .atomic)
        }
    }

    private func offerClaudeLogin() {
        let alert = NSAlert()
        alert.messageText = "需要登录一次 Claude Code"
        alert.informativeText = "课译通过你电脑上的 Claude Code 生成总结，使用你的 Claude 订阅额度，不额外收费。\n\n点“打开终端登录”后，在终端里输入 /login 并选择用 Claude 账号（订阅）登录，完成后关闭终端，再用“文件 › 重新生成课后总结”即可。只需登录一次。"
        alert.addButton(withTitle: "打开终端登录")
        alert.addButton(withTitle: "以后再说")
        guard alert.runModal() == .alertFirstButtonReturn, let cli = ClaudeSummarizer.locate() else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("课译-登录Claude.command")
        let escaped = cli.path.replacingOccurrences(of: "'", with: "'\\''")
        let body = "#!/bin/zsh\nunset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN\ncd ~\necho '在下面输入 /login 登录 Claude 账号，完成后可关闭此窗口。'\nexec '\(escaped)'\n"
        do {
            try Data(body.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            showMessage("无法打开终端", error.localizedDescription)
        }
    }

    private func performFind(_ action: NSTextFinder.Action) {
        if !window.isVisible { showMainWindow() }
        window.makeFirstResponder(captionView)
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        captionView.performFindPanelAction(sender)
    }

    @objc private func showFind() { performFind(.showFindInterface) }
    @objc private func findNext() { performFind(.nextMatch) }
    @objc private func findPrevious() { performFind(.previousMatch) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleCapture):
            menuItem.title = sessionActive ? "停止收声" : "开始收声"
            return !finishing && !savePanelOpen
        case #selector(togglePause):
            menuItem.title = isPaused ? "继续收声" : "暂停收声"
            return sessionActive && !finishing && worker != nil
        case #selector(toggleMark):
            return !captionTimeline.lines.isEmpty
        case #selector(toggleReview):
            menuItem.title = isReviewing ? "回到实时" : "回看"
            return true
        case #selector(toggleAlwaysOnTop):
            menuItem.state = alwaysOnTop ? .on : .off
            return true
        case #selector(exportTranscript):
            return archive != nil || savedTranscriptURL != nil
        case #selector(revealTranscript):
            return savedTranscriptURL != nil
        case #selector(toggleClaudeSummary):
            menuItem.state = ClaudeSummarizer.enabled ? .on : .off
            return true
        case #selector(regenerateSummary):
            return !sessionActive && !finishing && !captionTimeline.lines.isEmpty && !claudeSummaryRunning
        default:
            return true
        }
    }

    @objc private func showFloating() {
        if isReviewing { toggleReview() }
        if floatingWindow == nil {
            let floating = FloatingCaptionWindow()
            floating.onReturn = { [weak self] in self?.showMainWindow() }
            floatingWindow = floating
        }
        renderCaptions()
        floatingWindow?.show()
        window.orderOut(nil)
    }

    @objc private func showImmersive() {
        if isReviewing { toggleReview() }
        if immersiveWindow == nil {
            let immersive = ImmersiveCaptionWindow()
            immersive.onReturn = { [weak self] in self?.showMainWindow() }
            immersiveWindow = immersive
        }
        renderCaptions()
        immersiveWindow?.show(on: window.screen)
        window.orderOut(nil)
    }

    private func showMainWindow() {
        floatingWindow?.hide()
        immersiveWindow?.hide()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        window.level = alwaysOnTop ? .floating : .normal
        topButton.title = alwaysOnTop ? "置顶：开" : "置顶：关"
        UserDefaults.standard.set(alwaysOnTop, forKey: "TingYiAlwaysOnTop")
    }

    @objc private func decreaseFont() { changeFont(by: -2) }
    @objc private func increaseFont() { changeFont(by: 2) }

    private func changeFont(by amount: CGFloat) {
        captionFontSize = min(34, max(14, captionFontSize + amount))
        UserDefaults.standard.set(Double(captionFontSize), forKey: "TingYiCaptionFontSize")
        renderCaptions()
    }

    private func showMessage(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

/// 标题变化时自动换成对应 SF Symbol 的按钮（开始/停止、暂停/继续、回看/回到实时……）。
final class StateButton: NSButton {
    private var symbols: [String: String] = [:]
    /// 实心胶囊（主操作按钮）的填充色；为 nil 时是无边框的“图标 + 文字”按钮。
    var fillColor: NSColor? { didSet { restyle() } }
    var textColor: NSColor = .labelColor { didSet { restyle() } }

    convenience init(symbols: [String: String], iconOnly: Bool = false) {
        self.init(frame: .zero)
        self.symbols = symbols
        isBordered = iconOnly
        bezelStyle = iconOnly ? .toolbar : .regularSquare
        imagePosition = iconOnly ? .imageOnly : .imageLeading
        imageHugsTitle = true
        symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    }

    override var title: String {
        didSet {
            if let name = symbols[title] {
                image = NSImage(systemSymbolName: name, accessibilityDescription: title)
            }
            setAccessibilityLabel(title)
            restyle()
        }
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if fillColor != nil { size.width += 28 } else if imagePosition != .imageOnly { size.width += 8 }
        return size
    }

    private func restyle() {
        guard imagePosition != .imageOnly else { return }
        let color = fillColor == nil ? textColor : .white
        contentTintColor = color
        let weight: NSFont.Weight = fillColor == nil ? .medium : .semibold
        attributedTitle = NSAttributedString(string: super.title, attributes: [
            .font: NSFont.systemFont(ofSize: fillColor == nil ? 13 : 14, weight: weight),
            .foregroundColor: color
        ])
        if let fillColor {
            wantsLayer = true
            layer?.backgroundColor = fillColor.cgColor
            layer?.cornerRadius = 20
            layer?.cornerCurve = .continuous
        }
        invalidateIntrinsicContentSize()
    }
}

/// 让 AppKit 控件的 target/action 调用一个闭包。
final class ClosureTarget: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
}

@main
enum AppEntry {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
