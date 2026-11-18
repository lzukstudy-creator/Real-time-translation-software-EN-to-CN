import SwiftUI

// MARK: 设置

struct SettingsView: View {
    @EnvironmentObject private var session: LectureSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.keyiTheme) private var theme
    @AppStorage(ThemeID.storageKey) private var themeID = ThemeID.auto.rawValue
    @AppStorage(CaptionAppearance.sizeKey) private var captionSize = 21.0
    @AppStorage(CaptionAppearance.designKey) private var designID = "default"
    @AppStorage(CaptionAppearance.colorKey) private var colorID = "system"
    @AppStorage(CaptionAppearance.modeKey) private var modeID = "both"
    @AppStorage("KeepScreenOn") private var keepScreenOn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ThemePicker(selection: $themeID)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                        .listRowBackground(Color.clear)
                } header: { Text("主题") }

                Section {
                    CaptionRow(line: .init(id: 0, english: "A recursive call pushes a new stack frame.",
                                           chinese: "递归调用会压入一个新的栈帧。", marked: false),
                               latest: true, size: captionSize,
                               fonts: CaptionAppearance.fonts(designID, theme: theme),
                               colors: CaptionAppearance.colors(colorID, theme: theme), mode: modeID, theme: theme)
                        .padding(14)
                        .background(ThemeBackground(theme: theme).clipShape(RoundedRectangle(cornerRadius: 14)))
                        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                } header: { Text("预览") }

                Section("字幕") {
                    Picker("显示", selection: $modeID) {
                        ForEach(CaptionAppearance.modes, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("字号") {
                        Slider(value: $captionSize, in: 15...36, step: 1)
                    }
                    Picker("字体", selection: $designID) {
                        ForEach(CaptionAppearance.designs, id: \.id) {
                            Text($0.title).font(.system(.body, design: $0.design)).tag($0.id)
                        }
                    }
                    Picker("颜色", selection: $colorID) {
                        ForEach(CaptionAppearance.colors, id: \.id) { Text($0.title).tag($0.id) }
                    }
                }

                Section {
                    Toggle("收声时保持屏幕常亮", isOn: $keepScreenOn)
                        .onChange(of: keepScreenOn) { session.keepScreenOn = keepScreenOn }
                } header: { Text("收声") } footer: {
                    Text("关闭时可以直接锁屏，课译会在后台继续收声，最省电；回到 App 即可看到全部字幕。")
                }

                Section("术语表") {
                    NavigationLink {
                        GlossaryView(store: session.glossary)
                    } label: {
                        LabeledContent("专业词", value: "\(session.glossary?.terms.count ?? 0) 条")
                    }
                }

                Section {
                    LabeledContent("开始收声", value: "Siri / 操作按钮 / 快捷指令")
                    LabeledContent("锁屏", value: "显示最新一句和时长")
                } header: { Text("快捷操作") } footer: {
                    Text("在“设置 › 操作按钮”里选“快捷指令 › 课译 › 开始收声”，上课时按一下侧边按钮就能开始；也可以对 Siri 说“用课译开始收声”。锁屏上可以直接标重点、暂停。")
                }

                Section {
                    LabeledContent("识别", value: "iPhone 本机 · Apple SpeechAnalyzer")
                    LabeledContent("翻译", value: "iPhone 本机 · Apple 翻译")
                } header: { Text("关于") } footer: {
                    Text("声音不会上传，也不会保存录音；只保存文字字幕。首次使用需要下载英文识别和英译中语言包。")
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: 主题选择

struct ThemePicker: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ThemeID.allCases) { id in
                    let theme = KeYiTheme.resolve(id, system: systemScheme)
                    let selected = selection == id.rawValue
                    Button { selection = id.rawValue } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                ThemeBackground(theme: theme)
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 3).fill(theme.english.opacity(0.5)).frame(width: 64, height: 5)
                                    RoundedRectangle(cornerRadius: 3).fill(theme.chinese).frame(width: 74, height: 7)
                                    Spacer(minLength: 0)
                                    Button {} label: { RecordGlyph(theme: theme, active: false, busy: false).scaleEffect(0.6) }
                                        .buttonStyle(RecordButtonStyle(theme: theme, active: false, size: 44))
                                        .allowsHitTesting(false)
                                }
                                .padding(.vertical, 14)
                            }
                            .frame(width: 104, height: 132)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1))
                            VStack(spacing: 1) {
                                Text(KeYiTheme.title(of: id)).font(.subheadline.weight(selected ? .semibold : .regular))
                                Text(id == .auto ? "晨雾 / 墨夜" : theme.subtitle)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 104)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("主题：\(KeYiTheme.title(of: id))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: 术语表

struct GlossaryView: View {
    let store: GlossaryStore?
    @State private var query = ""
    @State private var adding = false
    @State private var english = ""
    @State private var chinese = ""
    @State private var revision = 0

    private var results: [Term] {
        _ = revision
        let all = store?.terms ?? []
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return all }
        return all.filter { $0.english.lowercased().contains(text) || $0.chinese.contains(text) }
    }

    var body: some View {
        List(results.prefix(300), id: \.id) { term in
            VStack(alignment: .leading, spacing: 3) {
                Text(term.english).font(.body.weight(.semibold))
                Text(term.chinese).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "搜索英文或中文")
        .navigationTitle("术语表")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("添加术语", isPresented: $adding) {
            TextField("英文，例如 call stack", text: $english)
            TextField("中文，例如 调用栈", text: $chinese)
            Button("添加") {
                try? store?.add(english: english, chinese: chinese)
                english = ""
                chinese = ""
                revision += 1
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次开始收声时，新术语会作为识别提示。")
        }
    }
}

// MARK: 字幕记录

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var pendingDelete: URL?

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    ContentUnavailableView("还没有字幕记录", systemImage: "doc.text",
                                           description: Text("结束收声后，字幕会自动保存在这里。"))
                }
                ForEach(files, id: \.self) { file in
                    NavigationLink {
                        TranscriptView(url: file)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.deletingPathExtension().lastPathComponent).font(.body.weight(.medium))
                            Text(Self.size(of: file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = file }
                    }
                }
            }
            .navigationTitle("字幕记录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear(perform: reload)
            .confirmationDialog("删除这份字幕？删除后无法恢复。",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let url = pendingDelete { try? FileManager.default.removeItem(at: url) }
                    pendingDelete = nil
                    reload()
                }
            }
        }
    }

    private func reload() {
        let folder = LectureSession.transcriptDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        files = items.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func size(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct TranscriptView: View {
    let url: URL
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .toolbar { ToolbarItem(placement: .primaryAction) { ShareLink(item: url) } }
        .task { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取这份字幕。" }
    }
}

// MARK: 导出

struct ExportView: View {
    let files: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(files, id: \.self) { file in
                        ShareLink(item: file) {
                            Label(Self.title(for: file), systemImage: Self.icon(for: file))
                        }
                    }
                } footer: {
                    Text("可以发到微信、存到“文件”，或用隔空投送传到电脑。字幕也会自动保存在“文件”App › 我的 iPhone › 课译。")
                }
                if files.count > 1 {
                    ShareLink(items: files) { Label("全部分享", systemImage: "square.and.arrow.up.on.square") }
                }
            }
            .navigationTitle("导出")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private static func title(for url: URL) -> String {
        switch url.pathExtension {
        case "md": return "学习笔记（重点、术语、总结、全文）"
        case "srt": return "SRT 字幕（带时间轴）"
        default: return "英中对照全文（TXT）"
        }
    }

    private static func icon(for url: URL) -> String {
        switch url.pathExtension {
        case "md": return "note.text"
        case "srt": return "captions.bubble"
        default: return "doc.text"
        }
    }
}
