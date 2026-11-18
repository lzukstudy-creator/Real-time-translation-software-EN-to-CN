import SwiftUI

/// 三种苹果风格版式共用的动作（打开记录、导出、设置，主按钮）。
struct LayoutActions {
    let history: () -> Void
    let export: () -> Void
    let settings: () -> Void
    let record: () -> Void
}

// MARK: 共用控件

struct RecordButton: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        let busy = session.phase == .preparing || session.phase == .finishing
        Button(action: action) {
            RecordGlyph(theme: theme, active: session.isActive, busy: busy)
        }
        .buttonStyle(RecordButtonStyle(theme: theme, active: session.isActive, size: size))
        .disabled(busy)
        .accessibilityLabel(session.isActive ? "结束收声" : "开始收声")
    }
}

struct MarkButton: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    var size: CGFloat = 50

    var body: some View {
        Button { session.toggleMark() } label: {
            Image(systemName: "star.fill").font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(theme.highlight)
        }
        .buttonStyle(TactileButtonStyle(theme: theme, size: size, onPlate: true))
        .disabled(!session.hasCaptions)
        .accessibilityLabel("标记重点")
    }
}

struct PauseButton: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    var size: CGFloat = 50

    var body: some View {
        Button { session.togglePause() } label: {
            Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(TactileButtonStyle(theme: theme, size: size, onPlate: true))
        .disabled(!session.isActive)
        .accessibilityLabel(session.phase == .paused ? "继续收声" : "暂停收声")
    }
}

/// 右上角的玻璃胶囊：导出 + 设置。
struct GlassToolGroup: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    let actions: LayoutActions
    var height: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            Button(action: actions.export) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                    .frame(width: height - 4, height: height)
            }
            .disabled(!session.hasCaptions && session.savedURL == nil)
            .accessibilityLabel("导出")
            Button(action: actions.settings) {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                    .frame(width: height - 4, height: height)
            }
            .accessibilityLabel("设置")
        }
        .foregroundStyle(theme.chinese)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// 自动跟随最新一句的滚动区；手动往上翻时停止跟随，并出现“回到最新”。
struct FollowingScroll<Content: View>: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var bottomInset: CGFloat
    @Binding var jumpTarget: Int?
    let content: Content
    @State private var followLatest = true

    init(bottomInset: CGFloat = 170, jumpTarget: Binding<Int?> = .constant(nil), @ViewBuilder content: () -> Content) {
        self.bottomInset = bottomInset
        _jumpTarget = jumpTarget
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                    Color.clear.frame(height: bottomInset).id("bottom")
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 120
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
            .onChange(of: jumpTarget) {
                guard let target = jumpTarget else { return }
                followLatest = false
                withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(target, anchor: .center) }
                jumpTarget = nil
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
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 18)
                    .padding(.bottom, bottomInset)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }
}

private func copyCaption(_ line: LectureSession.DisplayLine) {
    UIPasteboard.general.string = line.english + (line.chinese.map { "\n" + $0 } ?? "")
}

private struct CaptionMenu: ViewModifier {
    @EnvironmentObject private var session: LectureSession
    let line: LectureSession.DisplayLine

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(line.marked ? "取消重点" : "标为重点", systemImage: line.marked ? "star.slash" : "star") {
                session.toggleMark(line: line.id)
            }
            Button("拷贝", systemImage: "doc.on.doc") { copyCaption(line) }
        }
    }
}

// MARK: 原生（浅色 / 深色）

/// 系统 App 的样子：大标题、分段控件、分组卡片、玻璃控制条。
struct NativeLayout: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptionAppearance.sizeKey) private var captionSize = 21.0
    @AppStorage(CaptionAppearance.designKey) private var designID = "default"
    @AppStorage(CaptionAppearance.colorKey) private var colorID = "system"
    @AppStorage(CaptionAppearance.modeKey) private var modeID = "both"
    let actions: LayoutActions

    var body: some View {
        ZStack(alignment: .bottom) {
            ThemeBackground(theme: theme)
            FollowingScroll(bottomInset: 180) {
                if session.lines.isEmpty && session.summary == nil {
                    emptyCard
                } else if !session.lines.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(session.lines) { line in
                            if line.id != session.lines.first?.id {
                                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 16)
                            }
                            row(line).id(line.id)
                                .modifier(CaptionMenu(line: line))
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                        }
                    }
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
                    .padding(.horizontal, 16)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: session.lines)
                }
                if let summary = session.summary {
                    SummaryCard(text: summary, theme: theme).padding(.horizontal, 16).padding(.top, 16)
                }
            }
            bottomControls
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: actions.history) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(TactileButtonStyle(theme: theme, size: 44))
                .accessibilityLabel("字幕记录")
                Spacer()
                GlassToolGroup(actions: actions)
            }
            Text("课译").font(.system(size: 34, weight: .bold)).foregroundStyle(theme.chinese)
                .padding(.top, 10).padding(.horizontal, 4)
            statusLine.padding(.horizontal, 4).padding(.top, 2)
            Picker("字幕", selection: $modeID) {
                Text("英中对照").tag("both")
                Text("仅英文").tag("english")
                Text("仅中文").tag("chinese")
            }
            .pickerStyle(.segmented)
            .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .background(theme.backgroundTop.ignoresSafeArea())
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if session.isActive {
                Circle().fill(theme.idleStops[0]).frame(width: 7, height: 7)
                    .opacity(session.phase == .paused ? 0.4 : 1)
                Text(ContentView.clock(session.elapsed))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(session.phase == .paused ? theme.secondary : theme.idleStops[0])
                    .contentTransition(.numericText())
                let marks = session.lines.filter(\.marked).count
                Text("· \(session.status)" + (marks > 0 ? " · 重点 \(marks)" : ""))
            } else {
                Text(session.phase == .idle ? session.detail : session.status)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(theme.secondary)
        .lineLimit(1)
    }

    private func row(_ line: LectureSession.DisplayLine) -> some View {
        let latest = line.id == session.lines.last?.id
        let fonts = CaptionAppearance.fonts(designID, theme: theme)
        let colors = CaptionAppearance.colors(colorID, theme: theme)
        let base = captionSize * (latest ? 1.05 : 0.86)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if latest && session.phase == .recording {
                    HStack(spacing: 5) {
                        Circle().fill(theme.accent).frame(width: 6, height: 6)
                        Text("正在说")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                } else if let seconds = line.seconds {
                    Text(ContentView.clock(seconds) + (line.marked ? " · 重点" : ""))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(theme.secondary)
                }
                if modeID != "english", let chinese = line.chinese, !chinese.isEmpty {
                    Text(chinese)
                        .font(.system(size: base, weight: latest ? .bold : .semibold, design: fonts.0))
                        .foregroundStyle(colors.0)
                }
                if modeID != "chinese" {
                    Text(line.english)
                        .font(.system(size: modeID == "english" ? base : base * 0.83,
                                      weight: modeID == "english" ? .semibold : .regular, design: fonts.1))
                        .italic(fonts.2 && modeID != "english")
                        .foregroundStyle(modeID == "english" ? colors.0 : colors.1)
                }
            }
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            if line.marked {
                Image(systemName: "star.fill").font(.system(size: 17)).foregroundStyle(theme.highlight)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(line.marked ? theme.markFill : .clear, in: Rectangle())
        .textSelection(.enabled)
    }

    /// 空白时像“设置”一样的分组卡片，列出使用要点。
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开始之前").font(.system(size: 13)).foregroundStyle(theme.secondary).padding(.horizontal, 16)
            VStack(spacing: 0) {
                tip("waveform.and.mic", .hex(0xFF3B30), "把手机放在桌上，对着老师")
                tip("captions.bubble.fill", theme.accent, "英文和中文逐句出现")
                tip("lock.fill", .hex(0x34C759), "锁屏继续收声，锁屏上能看字幕")
                tip("star.fill", .hex(0xFF9500), "老师强调的地方点 ★ 标为重点")
                tip("button.horizontal.top.press.fill", .hex(0x5856D6), "操作按钮或 Siri 一键开始")
                tip("lock.shield.fill", .hex(0x8E8E93), "全部本机识别和翻译，不联网", last: true)
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func tip(_ symbol: String, _ color: Color, _ text: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(text).font(.system(size: 16)).foregroundStyle(theme.chinese)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if !last { Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 58) }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if let term = session.hints.first, modeID != "english" {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed.fill")
                    Text(term.english).fontWeight(.semibold)
                    Text(term.chinese)
                }
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(theme.accent.opacity(theme.scheme == .dark ? 0.2 : 0.12), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: 28) {
                MarkButton(size: 50)
                RecordButton(size: 72, action: actions.record)
                PauseButton(size: 50)
            }
            .padding(.horizontal, 22).padding(.vertical, 10)
            .controlPlate(theme)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.3), value: session.hints.first?.english)
    }
}

// MARK: Pro

/// 专业软件的样子：波形时间轴（重点位置有橙色菱形，点一下跳到那一句）、时间码列、三格操作条。
struct ProLayout: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptionAppearance.sizeKey) private var captionSize = 21.0
    @AppStorage(CaptionAppearance.designKey) private var designID = "default"
    @AppStorage(CaptionAppearance.colorKey) private var colorID = "system"
    @AppStorage(CaptionAppearance.modeKey) private var modeID = "both"
    let actions: LayoutActions
    @State private var jumpTarget: Int?

    private static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)

    var body: some View {
        ZStack(alignment: .bottom) {
            ThemeBackground(theme: theme)
            FollowingScroll(bottomInset: 150, jumpTarget: $jumpTarget) {
                if session.lines.isEmpty && session.summary == nil {
                    emptyState
                }
                LazyVStack(spacing: 0) {
                    ForEach(session.lines) { line in
                        row(line).id(line.id)
                            .modifier(CaptionMenu(line: line))
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: session.lines)
                if let summary = session.summary {
                    SummaryCard(text: summary, theme: theme).padding(16)
                }
            }
            bottomControls
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                Rectangle().fill(theme.separator).frame(height: 0.5)
                WaveformTimeline(history: session.levelHistory, elapsed: session.elapsed,
                                 marks: session.lines.filter(\.marked).compactMap(\.seconds),
                                 accent: theme.accent, active: session.isActive) { seconds in
                    jumpTarget = session.lines.last(where: { ($0.seconds ?? 0) <= seconds + 1 })?.id
                        ?? session.lines.first?.id
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                .background(Color.hex(0x161618))
                Rectangle().fill(theme.separator).frame(height: 0.5)
            }
            .background(theme.backgroundTop.ignoresSafeArea())
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: actions.history) {
                Image(systemName: "list.bullet").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(TactileButtonStyle(theme: theme, size: 36))
            .accessibilityLabel("字幕记录")
            VStack(alignment: .leading, spacing: 1) {
                Text("课译").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.chinese)
                Text(session.isActive ? "本机识别 · 本机翻译" : session.status)
                    .font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                Circle().fill(session.isActive ? Color.hex(0xFF453A) : theme.secondary).frame(width: 7, height: 7)
                    .opacity(session.phase == .paused ? 0.4 : 1)
                Text(ContentView.clock(session.elapsed)).contentTransition(.numericText())
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(session.isActive ? Color.hex(0xFF453A) : theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(session.isActive ? Color.hex(0xFF453A).opacity(0.18) : theme.surface,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Button(action: actions.export) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(TactileButtonStyle(theme: theme, size: 36))
            .disabled(!session.hasCaptions && session.savedURL == nil)
            .accessibilityLabel("导出")
            Button(action: actions.settings) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(TactileButtonStyle(theme: theme, size: 36))
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func row(_ line: LectureSession.DisplayLine) -> some View {
        let latest = line.id == session.lines.last?.id
        let fonts = CaptionAppearance.fonts(designID, theme: theme)
        let colors = CaptionAppearance.colors(colorID, theme: theme)
        let base = captionSize * (latest ? 1.0 : 0.82)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(line.seconds.map(ContentView.clock) ?? "--:--")
                        .font(Self.mono)
                        .foregroundStyle(line.marked ? theme.accent : (latest ? theme.chinese : theme.secondary))
                    if line.marked { Diamond().fill(theme.accent).frame(width: 9, height: 9).padding(.leading, 1) }
                }
                .frame(width: 58, alignment: .leading)
                .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    if modeID != "english", let chinese = line.chinese, !chinese.isEmpty {
                        Text(chinese)
                            .font(.system(size: base, weight: latest ? .bold : (line.marked ? .semibold : .medium), design: fonts.0))
                            .foregroundStyle(colors.0)
                    }
                    if modeID != "chinese" {
                        Text(line.english)
                            .font(.system(size: modeID == "english" ? base : base * 0.78, design: fonts.1))
                            .italic(fonts.2 && modeID != "english")
                            .foregroundStyle(modeID == "english" ? colors.0 : colors.1)
                    }
                }
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, latest ? 14 : 12)
            .background(line.marked ? theme.markFill : .clear, in: Rectangle())
            Rectangle().fill(Color.hex(0x2C2C2E)).frame(height: 0.5)
        }
        .textSelection(.enabled)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("READY").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(2)
                .foregroundStyle(theme.accent)
            Text("点下方“开始”收声").font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.chinese)
            VStack(alignment: .leading, spacing: 6) {
                Text("· 上方波形是整节课的音量，菱形是你标的重点")
                Text("· 点波形上任意位置，字幕跳到那个时间")
                Text("· 锁屏后继续收声，全部本机处理")
            }
            .font(.system(size: 14)).foregroundStyle(theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if modeID != "english", !session.hints.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(session.hints.prefix(2).enumerated()), id: \.offset) { index, term in
                        HStack(spacing: 6) {
                            if index == 0 {
                                Text("TERM").font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.secondary)
                            }
                            Text(term.english).fontWeight(.semibold)
                            Text(term.chinese).foregroundStyle(theme.secondary)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(theme.chinese)
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
            HStack(spacing: 1) {
                Button { session.toggleMark() } label: {
                    HStack(spacing: 7) { Diamond().fill(theme.accent).frame(width: 11, height: 11); Text("标记") }
                }
                .buttonStyle(ProSegmentStyle())
                .disabled(!session.hasCaptions)
                .accessibilityLabel("标记重点")
                recordSegment
                Button { session.togglePause() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace))
                        Text(session.phase == .paused ? "继续" : "暂停")
                    }
                }
                .buttonStyle(ProSegmentStyle())
                .disabled(!session.isActive)
            }
            .background(theme.separator)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 15, y: 10)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.3), value: session.hints.first?.english)
    }

    private var recordSegment: some View {
        let busy = session.phase == .preparing || session.phase == .finishing
        return Button(action: actions.record) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    RoundedRectangle(cornerRadius: session.isActive ? 3 : 7, style: .continuous)
                        .fill(Color.hex(0xFF453A)).frame(width: 14, height: 14)
                }
                Text(session.isActive ? "结束" : "开始")
            }
            .animation(.spring(duration: 0.3), value: session.isActive)
        }
        .buttonStyle(ProSegmentStyle(emphasized: true))
        .disabled(busy)
        .accessibilityLabel(session.isActive ? "结束收声" : "开始收声")
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

/// 整节课的音量波形。前 10 分钟按 10 分钟铺满，之后整条压缩成整节课长度。
struct WaveformTimeline: View {
    let history: [Float]
    let elapsed: TimeInterval
    let marks: [TimeInterval]
    let accent: Color
    let active: Bool
    let onSeek: (TimeInterval) -> Void

    private var span: TimeInterval { max(600, (elapsed / 300).rounded(.up) * 300) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let step: CGFloat = 7
                        let count = max(1, Int(size.width / step))
                        let perBar = span / Double(count)
                        for index in 0..<count {
                            let start = Int(Double(index) * perBar)
                            let end = min(history.count, Int(Double(index + 1) * perBar))
                            let recorded = start < history.count
                            let value: CGFloat = recorded && end > start
                                ? CGFloat(history[start..<end].max() ?? 0) : (recorded ? CGFloat(history[start]) : 0)
                            let height = recorded ? max(4, 4 + value * (size.height - 6)) : 4
                            let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: 5, height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                         with: .color(Color.hex(0xEBEBF5).opacity(recorded ? 0.55 : 0.16)))
                        }
                    }
                    if active || elapsed > 0 {
                        RoundedRectangle(cornerRadius: 1).fill(.white)
                            .frame(width: 2, height: geometry.size.height + 8)
                            .offset(x: min(width - 2, width * elapsed / span), y: -4)
                    }
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, seconds in
                        Diamond().fill(accent).frame(width: 11, height: 11)
                            .offset(x: width * seconds / span - 5.5, y: -9)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard elapsed > 0 else { return }
                    onSeek(min(elapsed, max(0, Double(location.x / width) * span)))
                }
            }
            .frame(height: 44)
            HStack {
                ForEach(0..<4) { index in
                    Text(ContentView.clock(span * Double(index) / 3))
                    if index < 3 { Spacer() }
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.hex(0xEBEBF5).opacity(0.45))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("整节课的音量波形，已标记 \(marks.count) 处重点")
        .accessibilityHint("点一下跳到那个时间的字幕")
    }
}

// MARK: 专注

/// 只留最新一句的大字幕。点一下屏幕隐藏 / 显示按钮。
struct FocusLayout: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.keyiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CaptionAppearance.sizeKey) private var captionSize = 21.0
    @AppStorage(CaptionAppearance.designKey) private var designID = "default"
    @AppStorage(CaptionAppearance.colorKey) private var colorID = "system"
    @AppStorage(CaptionAppearance.modeKey) private var modeID = "both"
    let actions: LayoutActions
    @State private var controlsHidden = false

    private var showControls: Bool { !controlsHidden || !session.isActive }

    var body: some View {
        ZStack {
            ThemeBackground(theme: theme)
            if let summary = session.summary, !session.isActive {
                ScrollView {
                    SummaryCard(text: summary, theme: theme).padding(20).padding(.top, 70).padding(.bottom, 140)
                }
            } else {
                captions
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard session.isActive else { return }
            withAnimation(.smooth(duration: 0.25)) { controlsHidden.toggle() }
        }
        .overlay(alignment: .top) {
            if showControls { topBar.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .overlay(alignment: .bottom) {
            if showControls { bottomControls.transition(.opacity.combined(with: .move(edge: .bottom))) }
        }
        .onChange(of: session.isActive) { if !session.isActive { controlsHidden = false } }
        .persistentSystemOverlays(controlsHidden ? .hidden : .automatic)
    }

    private var topBar: some View {
        HStack {
            Button(action: actions.history) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(TactileButtonStyle(theme: theme, size: 40))
            .accessibilityLabel("字幕记录")
            Spacer()
            HStack(spacing: 6) {
                if session.isActive {
                    Circle().fill(Color.hex(0xFF453A)).frame(width: 7, height: 7)
                        .opacity(session.phase == .paused ? 0.4 : 1)
                    Text(ContentView.clock(session.elapsed)).monospacedDigit().contentTransition(.numericText())
                } else {
                    Text(session.status)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.chinese)
            .padding(.horizontal, 14).frame(height: 40)
            .glassEffect(.regular, in: .capsule)
            Spacer()
            GlassToolGroup(actions: actions, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    @ViewBuilder private var captions: some View {
        let fonts = CaptionAppearance.fonts(designID, theme: theme)
        let colors = CaptionAppearance.colors(colorID, theme: theme)
        let lines = session.lines.filter { !$0.english.isEmpty || !($0.chinese ?? "").isEmpty }
        if let latest = lines.last {
            VStack(alignment: .leading, spacing: 28) {
                if lines.count > 1 {
                    block(lines[lines.count - 2], big: false, fonts: fonts, colors: colors)
                        .opacity(0.38)
                        .id("prev-\(lines[lines.count - 2].id)")
                }
                block(latest, big: true, fonts: fonts, colors: colors).id("latest-\(latest.id)")
                if let term = session.hints.first, modeID != "english" {
                    HStack(spacing: 8) {
                        Image(systemName: "character.book.closed.fill")
                        Text(term.english).fontWeight(.semibold)
                        Text(term.chinese)
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 70)
            .padding(.bottom, showControls ? 150 : 40)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: latest.id)
            .animation(.smooth(duration: 0.25), value: showControls)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "captions.bubble").font(.system(size: 36, weight: .semibold)).foregroundStyle(theme.accent)
                Text("只显示最新一句的大字幕").font(.system(size: 22, weight: .bold)).foregroundStyle(theme.chinese)
                Text("开始收声后，点一下屏幕可以隐藏按钮；\n横过来看，字更大。")
                    .font(.system(size: 15)).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
        }
    }

    private func block(_ line: LectureSession.DisplayLine, big: Bool,
                       fonts: (Font.Design, Font.Design, Bool), colors: (Color, Color)) -> some View {
        let primary = captionSize * (big ? 1.6 : 0.95)
        return VStack(alignment: .leading, spacing: big ? 12 : 6) {
            if line.marked && big {
                Label("重点", systemImage: "star.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.highlight)
            }
            if modeID != "english", let chinese = line.chinese, !chinese.isEmpty {
                Text(chinese)
                    .font(.system(size: primary, weight: big ? .bold : .semibold, design: fonts.0))
                    .foregroundStyle(colors.0)
                    .lineSpacing(big ? 4 : 2)
                    .minimumScaleFactor(0.6)
            }
            if modeID != "chinese" {
                Text(line.english)
                    .font(.system(size: modeID == "english" ? primary : primary * (big ? 0.56 : 0.75),
                                  weight: modeID == "english" ? .bold : .regular, design: fonts.1))
                    .italic(fonts.2 && modeID != "english")
                    .foregroundStyle(modeID == "english" ? colors.0 : colors.1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CaptionMenu(line: line))
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 24)), removal: .opacity))
    }

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if session.isActive {
                Text("点一下屏幕隐藏按钮 · 横过来字更大").font(.system(size: 13)).foregroundStyle(theme.secondary)
            }
            HStack(spacing: 22) {
                MarkButton(size: 48)
                RecordButton(size: 64, action: actions.record)
                PauseButton(size: 48)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .controlPlate(theme)
        }
        .padding(.bottom, 8)
    }
}
