import SwiftUI

/// 主界面：上方状态，中间字幕（自动跟随最新），下方术语提示和玻璃控制条。
struct ContentView: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.colorScheme) private var colorScheme
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
        NavigationStack {
            ZStack(alignment: .bottom) {
                background.ignoresSafeArea()
                captions
                VStack(spacing: 10) {
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
            .navigationTitle("课译")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("字幕记录")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(!session.hasCaptions && session.savedURL == nil)
                        .accessibilityLabel("导出")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .safeAreaInset(edge: .top) { statusHeader }
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

    // MARK: 背景与状态

    private var background: some View {
        LinearGradient(colors: colorScheme == .dark
                       ? [Color(red: 0.07, green: 0.09, blue: 0.15), Color(red: 0.04, green: 0.05, blue: 0.09)]
                       : [Color(red: 0.97, green: 0.98, blue: 1.0), Color(red: 0.93, green: 0.95, blue: 0.99)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.phase == .recording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .symbolEffect(.pulse, isActive: session.phase == .recording)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.status).font(.subheadline.weight(.semibold))
                Text(session.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.isActive {
                LevelBars(level: session.level).frame(width: 40, height: 18)
                Text(Self.clock(session.elapsed))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottomTrailing) {
            // 系统翻译需要这个视图在界面里才会运行；同时显示翻译状态。
            ChineseTranslationHost(translator: session.translator)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
    }

    // MARK: 字幕

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if session.lines.isEmpty && session.summary == nil {
                        emptyState
                    }
                    ForEach(session.lines) { line in
                        CaptionRow(line: line, size: captionSize, design: CaptionAppearance.design(designID),
                                   colors: CaptionAppearance.colors(colorID, dark: colorScheme == .dark),
                                   mode: modeID)
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
                        SummaryCard(text: summary).transition(.opacity)
                    }
                    Color.clear.frame(height: 150).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: session.lines)
            }
            .scrollDismissesKeyboard(.immediately)
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
                            .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                    .buttonStyle(.glass)
                    .padding(.trailing, 18)
                    .padding(.bottom, 150)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            Text("把手机放在桌上，对着老师的方向").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Label("英文和中文字幕会逐句出现在这里", systemImage: "captions.bubble")
                Label("锁屏后也会继续收声，省电又完整", systemImage: "lock.iphone")
                Label("老师强调的内容，点 ☆ 标为重点", systemImage: "star")
                Label("全部在手机本机识别和翻译，不联网", systemImage: "lock.shield")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private func termPill(_ term: Term) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "character.book.closed.fill").foregroundStyle(.tint)
            Text(term.english).fontWeight(.semibold)
            Text("·").foregroundStyle(.secondary)
            Text(term.chinese)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .capsule)
    }

    // MARK: 控制条

    private var controlBar: some View {
        HStack(spacing: 22) {
            Button { session.toggleMark() } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!session.hasCaptions)
            .accessibilityLabel("标记重点")

            Button {
                switch session.phase {
                case .idle: session.start()
                case .recording, .paused: confirmStop = true
                default: break
                }
            } label: {
                ZStack {
                    if session.phase == .preparing || session.phase == .finishing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: session.isActive ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 78, height: 78)
                .background(session.isActive ? Color.red : Color.accentColor, in: .circle)
                .shadow(color: (session.isActive ? Color.red : Color.accentColor).opacity(0.35), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(session.phase == .preparing || session.phase == .finishing)
            .accessibilityLabel(session.isActive ? "结束收声" : "开始收声")

            Button { session.togglePause() } label: {
                Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!session.isActive)
            .accessibilityLabel(session.phase == .paused ? "继续收声" : "暂停收声")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
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

/// 一句字幕：英文在上（略淡），中文在下（醒目）；重点句带星标和淡色底。
struct CaptionRow: View {
    let line: LectureSession.DisplayLine
    let size: Double
    let design: Font.Design
    let colors: (Color, Color)
    let mode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if mode != "chinese" {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if line.marked {
                        Image(systemName: "star.fill").foregroundStyle(.tint).font(.system(size: size * 0.7))
                    }
                    Text(line.english)
                        .font(.system(size: mode == "english" ? size : size * 0.86, design: design))
                        .foregroundStyle(mode == "english" ? colors.0 : colors.1)
                }
            }
            if mode != "english", let chinese = line.chinese, !chinese.isEmpty {
                Text(chinese)
                    .font(.system(size: size, weight: .medium, design: design))
                    .foregroundStyle(colors.0)
            }
        }
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(line.marked ? 12 : 0)
        .background {
            if line.marked {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.13))
            }
        }
        .textSelection(.enabled)
    }
}

/// 课后总结卡片。
struct SummaryCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("课后总结", systemImage: "sparkles").font(.headline).foregroundStyle(.tint)
            Text(text.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                .font(.callout)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 简洁的音量条。
struct LevelBars: View {
    let level: Float
    private let heights: [CGFloat] = [0.45, 0.8, 1.0, 0.65, 0.9]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Double(index) < Double(level) * Double(heights.count) ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 4)
                    .scaleEffect(y: heights[index], anchor: .center)
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}
