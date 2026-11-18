import SwiftUI

/// 主界面：上方状态，中间字幕（自动跟随最新），下方术语提示和玻璃控制条。
struct ContentView: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptionAppearance.sizeKey) private var captionSize = 21.0
    @AppStorage(CaptionAppearance.designKey) private var designID = "default"
    @AppStorage(CaptionAppearance.colorKey) private var colorID = "system"
    @AppStorage(CaptionAppearance.modeKey) private var modeID = "both"
    @State private var followLatest = true
    @State private var confirmStop = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showExport = false

    var body: some View {
        Group {
            switch theme.layout {
            case .classic: classicLayout
            case .native: NativeLayout(actions: actions)
            case .pro: ProLayout(actions: actions)
            case .focus: FocusLayout(actions: actions)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 系统翻译需要这个视图在界面里才会运行；放在最外层，换主题也不会中断。
            ChineseTranslationHost(translator: session.translator)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(session) }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showExport) { ExportView(files: session.exportFiles()) }
        .confirmationDialog("结束这节课的收声？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) { session.stop() }
            Button("继续收声", role: .cancel) {}
        } message: {
            Text("结束后会生成课后总结，字幕自动保存。")
        }
        .alert("出错了", isPresented: Binding(get: { session.errorMessage != nil },
                                            set: { if !$0 { session.errorMessage = nil } })) {
            Button("好") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var actions: LayoutActions {
        LayoutActions(history: { showHistory = true }, export: { showExport = true },
                      settings: { showSettings = true }, record: recordTapped)
    }

    private func recordTapped() {
        switch session.phase {
        case .idle: session.start()
        case .recording, .paused: confirmStop = true
        default: break
        }
    }

    /// 前四套主题（晨雾、墨夜、纸笺、石墨）的版式。
    private var classicLayout: some View {
        ZStack(alignment: .bottom) {
            ThemeBackground(theme: theme)
            captions
            VStack(spacing: 12) {
                if let term = session.hints.first, modeID != "english" {
                    termPill(term)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                controlBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.smooth(duration: 0.3), value: session.hints.first?.english)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 14) {
                topBar
                statusCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .background {
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundTop.opacity(0)], startPoint: .center, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: 顶栏与状态

    private var topBar: some View {
        HStack {
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(TactileButtonStyle(theme: theme, size: 44))
            .accessibilityLabel("字幕记录")
            Spacer()
            Text(theme.buttonKind == .metal ? "KEYI · 课译" : "课译")
                .font(.system(size: theme.buttonKind == .metal ? 14 : 17, weight: .semibold,
                              design: theme.buttonKind == .metal ? .monospaced : theme.chineseDesign))
                .tracking(theme.buttonKind == .metal ? 3 : (theme.buttonKind == .seal ? 3 : 0.5))
                .foregroundStyle(theme.buttonKind == .metal ? theme.secondary : theme.chinese)
            Spacer()
            HStack(spacing: 8) {
                Button { showExport = true } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(TactileButtonStyle(theme: theme, size: 44))
                .disabled(!session.hasCaptions && session.savedURL == nil)
                .accessibilityLabel("导出")
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(TactileButtonStyle(theme: theme, size: 44))
                .accessibilityLabel("设置")
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.phase == .recording ? Color.hex(0xFF5A4E) : theme.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .shadow(color: session.phase == .recording ? .hex(0xFF5A4E).opacity(0.7) : .clear, radius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.status).font(.system(size: 14, weight: .semibold, design: theme.chineseDesign))
                    .foregroundStyle(theme.chinese)
                Text(session.detail).font(.system(size: 12, design: theme.chineseDesign))
                    .foregroundStyle(theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.isActive {
                LevelBars(level: session.level, color: theme.accent, idle: theme.secondary.opacity(0.25))
                    .frame(width: 40, height: 18)
                Text(Self.clock(session.elapsed))
                    .font(.system(size: 15, weight: .semibold, design: theme.buttonKind == .metal ? .monospaced : .default)
                        .monospacedDigit())
                    .foregroundStyle(theme.scheme == .dark ? theme.accent : theme.chinese)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .themeSurface(theme)
    }

    // MARK: 字幕

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if session.lines.isEmpty && session.summary == nil {
                        emptyState
                    }
                    ForEach(session.lines) { line in
                        CaptionRow(line: line, latest: line.id == session.lines.last?.id, size: captionSize,
                                   fonts: CaptionAppearance.fonts(designID, theme: theme),
                                   colors: CaptionAppearance.colors(colorID, theme: theme),
                                   mode: modeID, theme: theme)
                            .contextMenu {
                                Button(line.marked ? "取消重点" : "标为重点",
                                       systemImage: line.marked ? "star.slash" : "star") {
                                    session.toggleMark(line: line.id)
                                }
                                Button("拷贝", systemImage: "doc.on.doc") {
                                    copy(line.english + (line.chinese.map { "\n" + $0 } ?? ""))
                                }
                            }
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                    }
                    if let summary = session.summary {
                        SummaryCard(text: summary, theme: theme).transition(.opacity)
                    }
                    Color.clear.frame(height: 170).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: session.lines)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
            } action: { _, nearBottom in
                followLatest = nearBottom
            }
            .onChange(of: session.lines) {
                guard followLatest else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.summary) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followLatest && !session.lines.isEmpty {
                    Button {
                        followLatest = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("回到最新", systemImage: "arrow.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(theme.chinese)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .themeSurface(theme, radius: 20)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 18)
                    .padding(.bottom, 170)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text("把手机放在桌上，对着老师的方向")
                .font(.system(size: 20, weight: .semibold, design: theme.chineseDesign))
                .foregroundStyle(theme.chinese)
            VStack(alignment: .leading, spacing: 9) {
                Label("英文和中文字幕会逐句出现在这里", systemImage: "captions.bubble")
                Label("锁屏后继续收声，锁屏上也能看到最新一句", systemImage: "lock.iphone")
                Label("老师强调的内容，点 ☆ 标为重点", systemImage: "star")
                Label("可以用操作按钮或 Siri 一键开始", systemImage: "button.horizontal.top.press")
                Label("全部在手机本机识别和翻译，不联网", systemImage: "lock.shield")
            }
            .font(.system(size: 15, design: theme.chineseDesign))
            .foregroundStyle(theme.secondary)
        }
        .padding(.top, 30)
    }

    private func termPill(_ term: Term) -> some View {
        HStack(spacing: 8) {
            if theme.buttonKind == .seal {
                Text("术语").font(.system(size: 12, weight: .bold, design: .serif))
                    .foregroundStyle(Color.hex(0xFBF3E6))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.hex(0x2B2419), in: RoundedRectangle(cornerRadius: 3))
            } else if theme.buttonKind == .metal {
                Text("TERM").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(theme.accent)
            } else {
                Image(systemName: "character.book.closed.fill").foregroundStyle(theme.accent)
            }
            Text(term.english).fontWeight(.semibold)
                .fontDesign(theme.buttonKind == .metal ? .monospaced : theme.englishDesign)
            Text(theme.buttonKind == .metal ? "→" : "·").foregroundStyle(theme.secondary)
            Text(term.chinese).fontDesign(theme.chineseDesign)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(theme.chinese)
        .lineLimit(1)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .themeSurface(theme, radius: theme.buttonKind == .candy || theme.buttonKind == .glow ? 22 : 10, inset: true)
    }

    // MARK: 控制条

    private var controlBar: some View {
        HStack(spacing: theme.buttonKind == .metal ? 34 : 26) {
            Button { session.toggleMark() } label: {
                Image(systemName: theme.buttonKind == .seal ? "star" : "star.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(theme.buttonKind == .metal ? Color.hex(0x24272B) : theme.accent)
            }
            .buttonStyle(TactileButtonStyle(theme: theme, size: theme.buttonKind == .metal ? 56 : 54))
            .disabled(!session.hasCaptions)
            .accessibilityLabel("标记重点")

            Button(action: recordTapped) {
                RecordGlyph(theme: theme, active: session.isActive,
                            busy: session.phase == .preparing || session.phase == .finishing)
            }
            .buttonStyle(RecordButtonStyle(theme: theme, active: session.isActive,
                                           size: theme.buttonKind == .metal ? 84 : 78))
            .disabled(session.phase == .preparing || session.phase == .finishing)
            .accessibilityLabel(session.isActive ? "结束收声" : "开始收声")

            Button { session.togglePause() } label: {
                Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(TactileButtonStyle(theme: theme, size: theme.buttonKind == .metal ? 56 : 54))
            .disabled(!session.isActive)
            .accessibilityLabel(session.phase == .paused ? "继续收声" : "暂停收声")
        }
        .padding(.horizontal, theme.buttonKind == .metal ? 30 : 24)
        .padding(.vertical, 13)
        .frame(maxWidth: theme.buttonKind == .metal ? .infinity : nil)
        .controlPlate(theme)
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 一句字幕：英文在上（略淡），中文在下（醒目）；最新一句稍大；重点句带星标和底色。
struct CaptionRow: View {
    let line: LectureSession.DisplayLine
    var latest = false
    let size: Double
    let fonts: (Font.Design, Font.Design, Bool)
    let colors: (Color, Color)
    let mode: String
    let theme: KeYiTheme

    var body: some View {
        let scale = latest ? 1.12 : 1.0
        VStack(alignment: .leading, spacing: 5) {
            if mode != "chinese" {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if line.marked { markBadge }
                    Text(line.english)
                        .font(.system(size: (mode == "english" ? size : size * 0.78) * scale,
                                      weight: mode == "english" ? .medium : .regular, design: fonts.1))
                        .italic(fonts.2 && mode != "english")
                        .foregroundStyle(mode == "english" ? colors.0 : colors.1)
                }
            }
            if mode != "english", let chinese = line.chinese, !chinese.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if line.marked && mode == "chinese" { markBadge }
                    Text(chinese)
                        .font(.system(size: size * scale, weight: latest || line.marked ? .semibold : .medium, design: fonts.0))
                        .foregroundStyle(colors.0)
                }
            }
        }
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(line.marked ? 14 : 0)
        .background {
            if line.marked {
                RoundedRectangle(cornerRadius: theme.corner, style: .continuous).fill(theme.markFill)
                    .overlay(RoundedRectangle(cornerRadius: theme.corner, style: .continuous)
                        .strokeBorder(theme.markStroke, lineWidth: 1))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private var markBadge: some View {
        if theme.buttonKind == .seal {
            Text("重点").font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.accent, lineWidth: 1))
        } else {
            Image(systemName: "star.fill").foregroundStyle(theme.accent).font(.system(size: size * 0.62))
        }
    }
}

/// 课后总结卡片。
struct SummaryCard: View {
    let text: String
    let theme: KeYiTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("课后总结", systemImage: "sparkles").font(.headline).foregroundStyle(theme.accent)
            Text(text.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                .font(.system(.callout, design: theme.chineseDesign))
                .foregroundStyle(theme.chinese)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeSurface(theme, radius: 20)
    }
}

/// 简洁的音量条。
struct LevelBars: View {
    let level: Float
    var color: Color = .accentColor
    var idle: Color = .secondary.opacity(0.25)
    private let heights: [CGFloat] = [0.45, 0.8, 1.0, 0.65, 0.9]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Double(index) < Double(level) * Double(heights.count) ? color : idle)
                    .frame(width: 4)
                    .scaleEffect(y: heights[index], anchor: .center)
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}
