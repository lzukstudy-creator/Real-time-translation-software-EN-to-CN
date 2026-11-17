import AVFoundation
import Foundation
import Speech

/// iPhone 上的英文实时识别：麦克风 → 苹果本机 SpeechAnalyzer（iOS 26，神经网络芯片运行，省电、不联网）。
/// 结果分两部分：已定稿（isFinal）的文字和正在说的临时文字，合起来就是完整英文。
@MainActor
final class LiveTranscriber {
    enum Failure: LocalizedError {
        case unsupportedLocale, noAudioFormat, microphoneDenied
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: return "这台 iPhone 不支持英文本机识别。"
            case .noAudioFormat: return "无法准备识别所需的音频格式。"
            case .microphoneDenied: return "没有麦克风权限。请在“设置 › 课译”中允许麦克风。"
            }
        }
    }

    /// 完整英文（已定稿 + 正在说的部分）有变化时回调。
    var onText: ((String) -> Void)?
    /// 0…1 的输入音量，用于界面上的音量条。
    var onLevel: ((Float) -> Void)?
    /// 识别中途出错（例如被系统中断）。
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var pipe: AudioPipe?
    private var finalized = ""
    private var volatile = ""
    private(set) var isRunning = false
    private(set) var isPaused = false

    var text: String { Self.join(finalized, volatile) }

    /// 首次使用时系统可能需要下载英文识别模型（几十 MB，之后离线可用）。
    func prepare(contextualStrings: [String], progress: @escaping (String) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw Failure.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("正在下载英文识别模型（只需一次）…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            // 术语表作为识别提示，让 “call stack” 这类专业词更容易被听对。
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
    }

    func start() async throws {
        guard let analyzer, let transcriber, let analyzerFormat else { throw Failure.noAudioFormat }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
        try configureSession()

        finalized = ""
        volatile = ""
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(400))
        input = continuation
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        self.finalized = Self.join(self.finalized, piece)
                        self.volatile = ""
                    } else {
                        self.volatile = piece
                    }
                    self.onText?(self.text)
                }
            } catch {
                self?.onError?("识别中断：\(error.localizedDescription)")
            }
        }

        let node = engine.inputNode
        let inputFormat = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else { throw Failure.noAudioFormat }
        let pipe = AudioPipe(converter: converter, format: analyzerFormat, continuation: continuation) { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        self.pipe = pipe
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            pipe.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        isPaused = false
    }

    /// 暂停：停止采集麦克风，识别器和已有字幕保留。
    func pause() {
        guard isRunning, !isPaused else { return }
        engine.pause()
        isPaused = true
        onLevel?(0)
    }

    func resume() throws {
        guard isRunning, isPaused else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        isPaused = false
    }

    /// 结束：把最后一句也识别完，再返回完整英文。
    func stop() async -> String {
        guard isRunning else { return text }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
        isRunning = false
        isPaused = false
        onLevel?(0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return text
    }

    // MARK: 音频

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .record + 后台音频模式：锁屏后继续收声。
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
    }

    private static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}

/// 在音频线程上同步转换并送入识别器（引擎会复用缓冲区，不能留到以后再处理）。
private final class AudioPipe: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let report: (Float) -> Void
    private var levelCounter = 0

    init(converter: AVAudioConverter, format: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation, report: @escaping (Float) -> Void) {
        self.converter = converter
        self.format = format
        self.continuation = continuation
        self.report = report
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        levelCounter += 1
        if levelCounter % 3 == 0 { report(Self.level(of: buffer)) }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var provided = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // 约 -55 dB … -10 dB 映射到 0 … 1
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 55) / 45))
    }
}
