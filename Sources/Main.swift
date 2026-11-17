import AppKit
import AVFoundation
import Darwin
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 670),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "课译"
        window.delegate = self
        window.minSize = NSSize(width: 880, height: 570)
        window.level = alwaysOnTop ? .floating : .normal
        window.center()

        themeRoot = ThemeRootView()
        themeRoot.wantsLayer = true
        themeRoot.onAppearanceChange = { [weak self] in self?.applyTheme() }
        window.contentView = themeRoot

        let brandIcon = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            brandIcon.image = NSImage(contentsOf: iconURL)
        }
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        let title = label("课译", size: 24, weight: .bold, color: .labelColor)
        let subtitle = label("实时听课 · 英中对照", size: 12, weight: .regular, color: .secondaryLabelColor)

        let languagePicker = NSPopUpButton()
        languagePicker.addItems(withTitles: ["英中对照", "纯英语"])
        languagePicker.selectItem(at: englishOnly ? 1 : 0)
        languagePicker.target = self
        languagePicker.action = #selector(changeLanguage(_:))
        accentPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        accentPicker.identifier = NSUserInterfaceItemIdentifier("accentPicker")
        accentPicker.target = self
        accentPicker.action = #selector(selectAccent(_:))
        for choice in AccentChoice.allCases { accentPicker.addItem(withTitle: choice.title) }
        accentPicker.selectItem(at: AccentChoice.allCases.firstIndex(of: accentChoice) ?? 0)
        accentPicker.toolTip = "切换课译的点缀色"

        glossaryButton = NSButton(title: "术语表", target: self, action: #selector(showGlossary))
        immersiveButton = NSButton(title: "沉浸字幕", target: self, action: #selector(showImmersive))

        statusCard = NSView()
        statusCard.wantsLayer = true
        let translationStatusView = NSHostingView(rootView: ChineseTranslationHost(translator: translator))
        statusLabel = label("准备就绪", size: 17, weight: .semibold, color: .labelColor)
        detailLabel = label("", size: 12, weight: .regular, color: .secondaryLabelColor)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        deviceLabel = label("", size: 11, weight: .regular, color: .secondaryLabelColor)
        hintLabel = label("专业词提示会显示在这里", size: 12, weight: .regular,
                          color: .secondaryLabelColor)
        hintLabel.lineBreakMode = .byTruncatingTail

        levelIndicator = AudioLevelView()
        levelIndicator.identifier = NSUserInterfaceItemIdentifier("microphoneLevel")
        levelIndicator.setAccessibilityLabel("麦克风音量")

        actionButton = NSButton(title: "开始收声", target: self, action: #selector(toggleCapture))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.identifier = NSUserInterfaceItemIdentifier("captureButton")
        actionButton.keyEquivalent = "\r"

        pauseButton = NSButton(title: "暂停收声", target: self, action: #selector(togglePause))
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .large
        pauseButton.identifier = NSUserInterfaceItemIdentifier("pauseButton")
        pauseButton.toolTip = "暂时停止收声，字幕保留；可随时继续"
        pauseButton.isHidden = true

        exportButton = NSButton(title: "导出字幕", target: self, action: #selector(exportTranscript))
        fileButton = NSButton(title: "字幕文件", target: self, action: #selector(revealTranscript))
        exportButton.isEnabled = false
        fileButton.isEnabled = false

        reviewButton = NSButton(title: "回看", target: self, action: #selector(toggleReview))
        markButton = NSButton(title: "★ 标记重点", target: self, action: #selector(toggleMark))
        markButton.toolTip = "把老师正在讲的这一句标为重点（⌘B），保存的字幕里会单独列出"
        floatButton = NSButton(title: "悬浮字幕", target: self, action: #selector(showFloating))
        topButton = NSButton(title: alwaysOnTop ? "置顶：开" : "置顶：关",
                             target: self, action: #selector(toggleAlwaysOnTop))
        smallerButton = NSButton(title: "A−", target: self, action: #selector(decreaseFont))
        largerButton = NSButton(title: "A+", target: self, action: #selector(increaseFont))
        let footerLeft = NSStackView(views: [markButton!, reviewButton!, floatButton!, fileButton!, exportButton!, topButton!])
        footerLeft.orientation = .horizontal
        footerLeft.spacing = 8
        footerLeft.alignment = .centerY
        styleButton = makeCaptionStyleButton()
        let footerRight = NSStackView(views: [styleButton!, smallerButton!, largerButton!])
        footerRight.orientation = .horizontal
        footerRight.spacing = 6
        footerRight.alignment = .centerY

        transcriptCard = NSView()
        transcriptCard.wantsLayer = true
        let transcriptTitle = label("实时字幕", size: 14, weight: .semibold, color: .labelColor)
        let transcriptNote = label("英中逐段对应 · 自动跟随最新内容", size: 11,
                                   weight: .regular, color: .secondaryLabelColor)
        transcriptDivider = NSView()
        transcriptDivider.wantsLayer = true
        let preview = NSScrollView()
        preview.hasVerticalScroller = true
        preview.borderType = .noBorder
        preview.drawsBackground = false
        captionView = CaptionTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 220))
        captionView.animatesCaptions = true
        captionView.usesFindBar = true
        captionView.isIncrementalSearchingEnabled = true
        captionView.isEditable = false
        captionView.isSelectable = true
        captionView.drawsBackground = false
        captionView.font = NSFont.systemFont(ofSize: captionFontSize)
        captionView.textContainerInset = NSSize(width: 20, height: 18)
        captionView.string = "英文和中文实时字幕将显示在这里"
        preview.documentView = captionView
        captionView.observeScrolling()

        for view in [brandIcon, title, subtitle, languagePicker, accentPicker!, glossaryButton!, immersiveButton!,
                     statusCard!, hintLabel!, transcriptCard!, footerLeft, footerRight] {
            view.translatesAutoresizingMaskIntoConstraints = false
            themeRoot.addSubview(view)
        }
        for view in [translationStatusView, statusLabel!, detailLabel!, deviceLabel!,
                     levelIndicator!, pauseButton!, actionButton!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            statusCard.addSubview(view)
        }
        for view in [transcriptTitle, transcriptNote, transcriptDivider!, preview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            transcriptCard.addSubview(view)
        }
        NSLayoutConstraint.activate([
            brandIcon.topAnchor.constraint(equalTo: themeRoot.topAnchor, constant: 22),
            brandIcon.leadingAnchor.constraint(equalTo: themeRoot.leadingAnchor, constant: 28),
            brandIcon.widthAnchor.constraint(equalToConstant: 42),
            brandIcon.heightAnchor.constraint(equalToConstant: 42),
            title.topAnchor.constraint(equalTo: brandIcon.topAnchor, constant: 1),
            title.leadingAnchor.constraint(equalTo: brandIcon.trailingAnchor, constant: 12),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            languagePicker.trailingAnchor.constraint(equalTo: glossaryButton.leadingAnchor, constant: -8),
            languagePicker.centerYAnchor.constraint(equalTo: accentPicker.centerYAnchor),
            accentPicker.trailingAnchor.constraint(equalTo: themeRoot.trailingAnchor, constant: -28),
            accentPicker.centerYAnchor.constraint(equalTo: brandIcon.centerYAnchor),
            accentPicker.widthAnchor.constraint(equalToConstant: 108),
            immersiveButton.trailingAnchor.constraint(equalTo: accentPicker.leadingAnchor, constant: -8),
            immersiveButton.centerYAnchor.constraint(equalTo: accentPicker.centerYAnchor),
            glossaryButton.trailingAnchor.constraint(equalTo: immersiveButton.leadingAnchor, constant: -8),
            glossaryButton.centerYAnchor.constraint(equalTo: accentPicker.centerYAnchor),
            glossaryButton.leadingAnchor.constraint(greaterThanOrEqualTo: subtitle.trailingAnchor, constant: 14),

            statusCard.topAnchor.constraint(equalTo: brandIcon.bottomAnchor, constant: 22),
            statusCard.leadingAnchor.constraint(equalTo: themeRoot.leadingAnchor, constant: 28),
            statusCard.trailingAnchor.constraint(equalTo: themeRoot.trailingAnchor, constant: -28),
            statusCard.heightAnchor.constraint(equalToConstant: 112),
            statusLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: translationStatusView.leadingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: levelIndicator.leadingAnchor, constant: -14),
            deviceLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 7),
            deviceLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            deviceLabel.trailingAnchor.constraint(lessThanOrEqualTo: levelIndicator.leadingAnchor, constant: -14),
            translationStatusView.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 10),
            translationStatusView.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -18),
            translationStatusView.widthAnchor.constraint(equalToConstant: 250),
            translationStatusView.heightAnchor.constraint(equalToConstant: 36),
            actionButton.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -18),
            actionButton.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -16),
            actionButton.widthAnchor.constraint(equalToConstant: 120),
            pauseButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            pauseButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: 110),
            levelIndicator.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -14),
            levelIndicator.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            levelIndicator.widthAnchor.constraint(equalToConstant: 76),
            levelIndicator.heightAnchor.constraint(equalToConstant: 28),

            hintLabel.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 9),
            hintLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 4),
            hintLabel.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -4),
            transcriptCard.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 10),
            transcriptCard.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor),
            transcriptCard.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor),
            transcriptCard.bottomAnchor.constraint(equalTo: footerLeft.topAnchor, constant: -14),
            transcriptTitle.topAnchor.constraint(equalTo: transcriptCard.topAnchor, constant: 15),
            transcriptTitle.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor, constant: 20),
            transcriptNote.centerYAnchor.constraint(equalTo: transcriptTitle.centerYAnchor),
            transcriptNote.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor, constant: -20),
            transcriptDivider.topAnchor.constraint(equalTo: transcriptCard.topAnchor, constant: 47),
            transcriptDivider.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor),
            transcriptDivider.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor),
            transcriptDivider.heightAnchor.constraint(equalToConstant: 1),
            preview.topAnchor.constraint(equalTo: transcriptDivider.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor, constant: 1),
            preview.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor, constant: -1),
            preview.bottomAnchor.constraint(equalTo: transcriptCard.bottomAnchor, constant: -1),

            footerLeft.leadingAnchor.constraint(equalTo: transcriptCard.leadingAnchor),
            footerLeft.bottomAnchor.constraint(equalTo: themeRoot.bottomAnchor, constant: -20),
            footerRight.trailingAnchor.constraint(equalTo: transcriptCard.trailingAnchor),
            footerRight.centerYAnchor.constraint(equalTo: footerLeft.centerYAnchor),
            footerLeft.trailingAnchor.constraint(lessThanOrEqualTo: footerRight.leadingAnchor, constant: -12)
        ])
        applyTheme()
        window.makeKeyAndOrderFront(nil)
    }

    private func applyTheme() {
        guard let root = themeRoot, let window else { return }
        let palette = AppPalette(appearance: root.effectiveAppearance, accent: accentChoice)
        window.backgroundColor = palette.background
        root.layer?.backgroundColor = palette.background.cgColor
        for card in [statusCard, transcriptCard] {
            card?.layer?.backgroundColor = palette.surface.cgColor
            card?.layer?.borderColor = palette.border.cgColor
            card?.layer?.borderWidth = 1
            card?.layer?.cornerRadius = 13
        }
        transcriptDivider?.layer?.backgroundColor = palette.border.cgColor
        statusLabel?.textColor = palette.text
        detailLabel?.textColor = palette.secondary
        deviceLabel?.textColor = palette.secondary
        hintLabel?.textColor = palette.secondary
        levelIndicator?.accentColor = palette.accent
        actionButton?.bezelColor = palette.accent
        captionView?.applyStyle(captionStyle, palette: palette)
        captionView?.markColor = palette.accent
        for (index, choice) in AccentChoice.allCases.enumerated() {
            accentPicker?.item(at: index)?.image = choice.swatch(dark: palette.dark)
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

    private func makeCaptionStyleButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.identifier = NSUserInterfaceItemIdentifier("captionStyleButton")
        button.toolTip = "切换字幕字体和颜色（中英文字幕同时生效）"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "字幕样式", action: nil, keyEquivalent: "")
        let fontHeader = NSMenuItem.sectionHeader(title: "字体")
        menu.addItem(fontHeader)
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
        menu.addItem(NSMenuItem.sectionHeader(title: "颜色"))
        for choice in CaptionColorChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectCaptionColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    private func refreshCaptionStyleMenu(palette: AppPalette) {
        guard let menu = styleButton?.menu else { return }
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
            markButton?.title = "★ 标记重点"
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
        hintLabel.isHidden = englishOnly
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
        markButton.title = marked ? "★ 已标记" : "★ 标记重点"
        if marked {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.markButton.title = "★ 标记重点"
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
