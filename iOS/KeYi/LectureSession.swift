import AVFoundation
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 一节课的收声会话：识别 → 分句 → 翻译 → 自动保存 → 结束时总结。
/// 分句、翻译、存档、术语、导出、总结都与电脑版共用同一份代码（Sources/ 下的共享文件）。
@MainActor
final class LectureSession: ObservableObject {
    /// 整个 App 只有一个收声会话；快捷指令和锁屏按钮也通过它操作。
    static let shared = LectureSession()

    enum Phase: Equatable { case idle, preparing, recording, paused, finishing }

    struct DisplayLine: Identifiable, Equatable {
        let id: Int
        let english: String
        let chinese: String?
        let marked: Bool
        var seconds: TimeInterval? = nil
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "准备就绪"
    @Published private(set) var detail = "点下方按钮开始收声。锁屏后也会继续。"
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    /// 整节课的音量，每秒一个峰值，用来画 Pro 主题的波形时间轴。
    @Published private(set) var levelHistory: [Float] = []
    private var peakSinceTick: Float = 0
    @Published private(set) var lines: [DisplayLine] = []
    @Published private(set) var hints: [Term] = []
    @Published private(set) var summary: String?
    @Published private(set) var savedURL: URL?
    @Published var errorMessage: String?

    let translator = ChineseTranslation()
    private(set) var glossary: GlossaryStore?
    private var transcriber: LiveTranscriber?
    private var timeline = CaptionTimeline()
    private var archive: BilingualArchive?
    private var segmentTimes: [Int: Double] = [:]
    private var lectureTerms: [String: (english: String, chinese: String)] = [:]
    private var lectureTermOrder: [String] = []
    private var submitted: [Int: String] = [:]
    private var translationID = 0
    private var lastSubmit = 0.0
    private var translationScheduled = false
    private var clock: Timer?
    private var startedDate = Date()
    private var interruptionObserver: NSObjectProtocol?
    private let liveActivity = LiveCaptionActivity()

    var isActive: Bool { phase == .recording || phase == .paused }
    var hasCaptions: Bool { !timeline.lines.isEmpty }

    static var transcriptDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("课译字幕", isDirectory: true)
    }
    private static var stagingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TingYi/Recording", isDirectory: true)
    }

    init() {
        if let resource = Bundle.main.url(forResource: "coursepack", withExtension: "json") {
            let custom = Self.stagingDirectory.deletingLastPathComponent().appendingPathComponent("custom-terms.json")
            try? FileManager.default.createDirectory(at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
            glossary = try? GlossaryStore(resource: resource, customURL: custom)
        }
        let recovered = BilingualArchive.recover(staging: Self.stagingDirectory, destination: Self.transcriptDirectory)
        if !recovered.isEmpty {
            detail = "已找回 \(recovered.count) 份意外中断的字幕，可在“字幕记录”里查看。"
        }
        translator.onResult = { [weak self] input, chinese in
            guard let self, self.timeline.applyTranslation(segment: input.segment, english: input.english,
                                                           chinese: chinese) else { return }
            self.archive?.setTranslation(segment: input.segment, seconds: input.seconds,
                                         english: input.english, chinese: chinese)
            if self.timeline.isMarked(input.segment) { self.syncMarks() }
            self.publishLines()
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let resume = ((note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
                & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            Task { @MainActor in self?.handleInterruption(type, shouldResume: resume) }
        }
        KeYiIntentBridge.handler = { [weak self] action in self?.perform(action) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-KeYiDemo") { loadDemo() }
        #endif
    }

    #if DEBUG
    /// 仅调试版：填入示例字幕，用来截图检查各主题。
    private func loadDemo() {
        lines = [
            DisplayLine(id: 0, english: "So every time we call a function, a new stack frame gets pushed.",
                        chinese: "所以每次调用函数时，都会压入一个新的栈帧。", marked: false, seconds: 821),
            DisplayLine(id: 1, english: "This is exactly why deep recursion can overflow the stack.",
                        chinese: "这正是深度递归会导致栈溢出的原因。", marked: true, seconds: 842),
            DisplayLine(id: 2, english: "Let's look at what the frame actually stores.",
                        chinese: "我们来看看栈帧里实际存了什么。", marked: false, seconds: 1934)
        ]
        hints = Array((glossary?.suggestions(in: "the stack frame", context: "call stack frame") ?? []).prefix(1))
        phase = .recording
        status = "正在收声"
        detail = "本机识别 · 本机翻译 · 已标记 1 处"
        elapsed = 1938
        level = 0.6
        levelHistory = (0..<1938).map { second in
            let wave = 0.45 + 0.3 * sin(Double(second) / 37) + 0.15 * sin(Double(second) / 7.3)
            return Float(max(0.08, min(1, wave + Double((second * 7919) % 13) / 60)))
        }
    }
    #endif

    /// 快捷指令、Siri、操作按钮、锁屏按钮的动作。
    func perform(_ action: KeYiAction) {
        switch action {
        case .start: if phase == .idle { start() }
        case .mark: toggleMark()
        case .pause: if isActive { togglePause() }
        case .stop: if isActive { stop() }
        }
    }

    // MARK: 收声

    func start() {
        guard phase == .idle else { return }
        phase = .preparing
        status = "正在准备"
        detail = "正在启动本机英文识别…"
        errorMessage = nil
        timeline = CaptionTimeline()
        segmentTimes = [:]
        submitted = [:]
        lectureTerms = [:]
        lectureTermOrder = []
        summary = nil
        hints = []
        elapsed = 0
        levelHistory = []
        peakSinceTick = 0
        startedDate = Date()
        publishLines()
        translator.prepare()
        let transcriber = LiveTranscriber()
        transcriber.onText = { [weak self] text in self?.handleEnglish(text) }
        transcriber.onLevel = { [weak self] level in
            guard let self else { return }
            self.level = level
            self.peakSinceTick = max(self.peakSinceTick, level)
        }
        transcriber.onError = { [weak self] message in self?.errorMessage = message }
        self.transcriber = transcriber
        let hotwords = glossary?.hotwords ?? []
        Task {
            do {
                try await transcriber.prepare(contextualStrings: Array(hotwords.prefix(400))) { [weak self] text in
                    self?.detail = text
                }
                try await transcriber.start()
                archive = try BilingualArchive(stagingDirectory: Self.stagingDirectory,
                                               destinationDirectory: Self.transcriptDirectory)
                savedURL = archive?.destinationURL
                phase = .recording
                status = "正在收声"
                detail = "锁屏也会继续收声；字幕每秒自动保存。"
                startClock()
                applyIdleTimer()
                liveActivity.start(activityState)
            } catch {
                self.transcriber = nil
                phase = .idle
                status = "未能开始"
                detail = error.localizedDescription
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePause() {
        guard let transcriber else { return }
        if phase == .recording {
            transcriber.pause()
            phase = .paused
            status = "已暂停"
            detail = "字幕已保留，点继续接着收声。"
            submitTranslation()
        } else if phase == .paused {
            do {
                try transcriber.resume()
                phase = .recording
                status = "正在收声"
                detail = "已继续收声。"
            } catch {
                errorMessage = "继续收声失败：\(error.localizedDescription)"
            }
        }
        applyIdleTimer()
        liveActivity.update(activityState, immediate: true)
    }

    func stop() {
        guard isActive, let transcriber else { return }
        phase = .finishing
        status = "正在完成"
        detail = "正在识别最后一句并保存…"
        clock?.invalidate()
        Task {
            let text = await transcriber.stop()
            self.transcriber = nil
            if !text.isEmpty { handleEnglish(text) }
            submitTranslation()
            // 给最后几句翻译一点时间。
            try? await Task.sleep(for: .seconds(3))
            finish()
        }
    }

    private func finish() {
        liveActivity.end(activityState)
        summary = LectureSummary.make(lines: summaryLines, terms: termList)
        if let summary { archive?.setSummary(summary) }
        syncMarks()
        let archive = self.archive
        self.archive = nil
        archive?.finish(reason: "用户停止") { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(let url) = result { self.savedURL = url }
                self.phase = .idle
                self.status = "已保存"
                self.detail = "字幕已保存在“字幕记录”和“文件”App › 课译 里。"
                self.level = 0
                self.applyIdleTimer()
            }
        }
        if archive == nil {
            phase = .idle
            status = "准备就绪"
        }
        publishLines()
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        guard let type else { return }
        if type == .began, phase == .recording {
            transcriber?.pause()
            phase = .paused
            status = "已暂停"
            detail = "被来电或其他声音打断，已暂停；字幕已保留。"
            liveActivity.update(activityState, immediate: true)
        } else if type == .ended, phase == .paused, shouldResume {
            togglePause()
        }
    }

    private func startClock() {
        clock?.invalidate()
        var last = Date()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                if self.phase == .recording {
                    self.elapsed += now.timeIntervalSince(last)
                    self.levelHistory.append(self.peakSinceTick)
                    self.peakSinceTick = 0
                }
                last = now
            }
        }
    }

    // MARK: 字幕与翻译

    private func handleEnglish(_ text: String) {
        timeline.updateEnglish(text)
        for index in timeline.lines.indices where segmentTimes[index] == nil { segmentTimes[index] = elapsed }
        archive?.setEnglish(text)
        let found = glossary?.suggestions(in: String(text.suffix(450)), context: String(text.suffix(1400))) ?? []
        hints = Array(found.prefix(3))
        for term in found where lectureTerms[term.english.lowercased()] == nil {
            lectureTerms[term.english.lowercased()] = (term.english, term.chinese)
            lectureTermOrder.append(term.english.lowercased())
        }
        publishLines()
        scheduleTranslation()
    }

    private func scheduleTranslation() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSubmit >= 1.4 { submitTranslation(); return }
        guard !translationScheduled else { return }
        translationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 - (now - lastSubmit)) { [weak self] in
            self?.translationScheduled = false
            self?.submitTranslation()
        }
    }

    private func submitTranslation() {
        let pending = timeline.lines.enumerated().filter { index, line in
            line.english.count >= 4 && submitted[index] != line.english
        }
        guard !pending.isEmpty else { return }
        lastSubmit = ProcessInfo.processInfo.systemUptime
        for (segment, line) in pending {
            submitted[segment] = line.english
            translationID += 1
            translator.submit(TranslationInput(id: translationID, session: 0, segment: segment,
                                               seconds: segmentTimes[segment] ?? elapsed, english: line.english))
        }
    }

    private func publishLines() {
        let next = timeline.lines.enumerated().map {
            DisplayLine(id: $0.offset, english: $0.element.english, chinese: $0.element.chinese,
                        marked: timeline.isMarked($0.offset), seconds: segmentTimes[$0.offset])
        }
        if next != lines {
            lines = next
            if isActive { liveActivity.update(activityState) }
        }
    }

    /// 锁屏实时字幕要显示的内容。
    private var activityState: LiveCaptionAttributes.ContentState {
        let chinese = lines.last(where: { !($0.chinese ?? "").isEmpty })?.chinese ?? ""
        return LiveCaptionAttributes.ContentState(
            chinese: chinese.isEmpty ? "正在听…" : String(chinese.suffix(90)),
            english: String((lines.last?.english ?? "").suffix(140)),
            startedAt: Date().addingTimeInterval(-elapsed),
            pausedElapsed: phase == .paused ? elapsed : nil,
            marks: timeline.marks.count)
    }

    // MARK: 重点、总结、导出

    func toggleMark() {
        guard hasCaptions else { return }
        let seconds = timeline.lines.indices.last.flatMap { segmentTimes[$0] } ?? elapsed
        timeline.toggleLatestMark(seconds: seconds)
        syncMarks()
        publishLines()
        liveActivity.update(activityState, immediate: true)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    func toggleMark(line id: Int) {
        // 点某一句的星标：只切换这一句。
        guard timeline.lines.indices.contains(id) else { return }
        timeline.toggleMark(at: id, seconds: segmentTimes[id] ?? elapsed)
        syncMarks()
        publishLines()
    }

    private func syncMarks() {
        let current = timeline.lines
        archive?.setMarks(timeline.marks.sorted { $0.key < $1.key }
            .filter { current.indices.contains($0.key) }
            .map { (seconds: $0.value, english: current[$0.key].english, chinese: current[$0.key].chinese) })
    }

    private var summaryLines: [LectureSummary.Line] {
        timeline.lines.enumerated().map {
            LectureSummary.Line(start: segmentTimes[$0.offset] ?? 0, english: $0.element.english,
                                chinese: $0.element.chinese, marked: timeline.isMarked($0.offset))
        }
    }

    private var termList: [(english: String, chinese: String)] {
        lectureTermOrder.compactMap { lectureTerms[$0] }
    }

    /// 生成可分享的文件：Markdown 学习笔记、SRT 字幕、英中对照 TXT。
    func exportFiles() -> [URL] {
        guard hasCaptions else { return savedURL.map { [$0] } ?? [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "课译 " + formatter.string(from: startedDate)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = timeline.lines.enumerated().map {
            LectureExport.Line(start: segmentTimes[$0.offset] ?? 0, english: $0.element.english,
                               chinese: $0.element.chinese, marked: timeline.isMarked($0.offset))
        }
        var files: [URL] = []
        let markdown = folder.appendingPathComponent(base + " 笔记.md")
        if (try? Data(LectureExport.markdown(lines, date: startedDate, terms: termList, summary: summary).utf8)
            .write(to: markdown)) != nil { files.append(markdown) }
        let srt = folder.appendingPathComponent(base + ".srt")
        if (try? Data(LectureExport.srt(lines, end: elapsed).utf8).write(to: srt)) != nil { files.append(srt) }
        if let savedURL { files.append(savedURL) }
        return files
    }

    // MARK: 屏幕常亮

    @AppStorage("KeepScreenOn") var keepScreenOn = false {
        didSet { applyIdleTimer() }
    }

    func applyIdleTimer() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn && isActive
        #endif
    }
}
