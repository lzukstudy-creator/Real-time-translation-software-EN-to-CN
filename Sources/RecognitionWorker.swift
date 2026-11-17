import AVFoundation
import Foundation

private struct AudioBufferCopy: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

final class RecognitionWorker: @unchecked Sendable {
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onWarning: ((String) -> Void)?

    private let decoder: StreamingDecoder
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "app.tingyi.recognition", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var pendingDuration = 0.0
    private var backlogWarningActive = false
    private var conversionWarningActive = false
    private var lastText = ""
    /// 第二遍精确识别（可选）。状态只在 queue 上读写；解码在 refineQueue 上进行。
    private let refiner: SentenceRefiner?
    private let refineQueue = DispatchQueue(label: "app.tingyi.refine", qos: .utility)
    private var transcript = TwoPassTranscript()
    private var streamingWords: [WordStamp] = []
    private var streamingText = ""
    private var refinesInFlight = 0
    private var segmenter = SentenceSegmenter()
    /// 积压太多时跳过较早的句子（保留实时结果），保证字幕不会越来越落后。
    private static let maximumRefinesInFlight = 3

    let enhanced: Bool
    var refining: Bool { refiner != nil }

    init(model: URL, inputFormat: AVAudioFormat, hotwords: [String] = [],
         refineModel: URL? = nil) throws {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000, channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecognitionError.unsupportedAudio
        }
        let required = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: model.appendingPathComponent($0).path) }) else {
            throw RecognitionError.missingModel
        }
        self.outputFormat = outputFormat
        self.converter = converter
        if hotwords.isEmpty {
            decoder = try StreamingDecoder(model: model.path)
        } else if let boosted = try? StreamingDecoder(model: model.path,
                                                       contextualTerms: hotwords,
                                                       paths: 2, score: 0.5) {
            decoder = boosted
        } else {
            decoder = try StreamingDecoder(model: model.path)
        }
        enhanced = decoder.enhanced
        if let refineModel {
            do {
                refiner = try SentenceRefiner(model: refineModel)
            } catch {
                NSLog("课译二次精确识别未启用：%@", error.localizedDescription)
                refiner = nil
            }
        } else {
            refiner = nil
        }
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard pendingDuration + duration <= 6 else {
            let report = !backlogWarningActive
            backlogWarningActive = true
            lock.unlock()
            if report { onWarning?("识别暂时落后，已跳过少量音频；收声继续。") }
            return
        }
        pendingDuration += duration
        lock.unlock()

        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            release(duration)
            return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count {
            guard let src = source[index].mData, let dst = target[index].mData else { continue }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        let owned = AudioBufferCopy(value: copy)
        queue.async { [self] in
            defer { release(duration) }
            let capacity = AVAudioFrameCount(ceil(Double(owned.value.frameLength) *
                                                   outputFormat.sampleRate /
                                                   owned.value.format.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var provided = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !provided else { inputStatus.pointee = .noDataNow; return nil }
                provided = true
                inputStatus.pointee = .haveData
                return owned.value
            }
            guard status != .error else {
                if !conversionWarningActive {
                    conversionWarningActive = true
                    onWarning?("麦克风音频转换失败，正在继续尝试。")
                    NSLog("课译音频转换失败：%@", conversionError?.localizedDescription ?? "未知错误")
                }
                return
            }
            if conversionWarningActive {
                conversionWarningActive = false
                onWarning?("音频转换已恢复，收声继续。")
            }
            guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let decoded = decoder.feed(samples)
            refiner?.feed(samples)
            guard decoded else { return }
            let (text, words, _) = decoder.result()
            streamingText = text
            streamingWords = words
            if let refiner {
                for cut in segmenter.cuts(words: words, audioEnd: refiner.audioEnd,
                                           speech: refiner.speechLevel, quiet: refiner.quietest) {
                    if let sentence = refiner.sentence(from: cut.start, to: cut.end) {
                        refine(sentence, required: false)
                    }
                }
            }
            publish()
        }
    }

    /// 在 queue 上调用：合成两遍识别的结果并通知界面。
    private func publish() {
        let text = transcript.compose(streaming: streamingWords, fallback: streamingText)
        guard text != lastText else { return }
        lastText = text
        onText?(text)
    }

    /// 在 queue 上调用。
    private func refine(_ sentence: PendingSentence, required: Bool, done: (() -> Void)? = nil) {
        guard let refiner else { done?(); return }
        if !required && refinesInFlight >= Self.maximumRefinesInFlight {
            NSLog("课译二次识别积压，跳过 %.1f–%.1f 秒，保留实时字幕", sentence.start, sentence.end)
            return
        }
        refinesInFlight += 1
        refineQueue.async { [self] in
            let segment = refiner.decode(sentence)
            queue.async { [self] in
                refinesInFlight -= 1
                if let segment {
                    transcript.add(segment)
                    publish()
                }
                done?()
            }
        }
    }

    func finish(completion: @escaping (String) -> Void) {
        lock.lock()
        accepting = false
        lock.unlock()
        queue.async { [self] in
            decoder.finish()
            let (text, words, _) = decoder.result()
            streamingText = text
            streamingWords = words
            var remaining: [PendingSentence] = []
            if let refiner {
                for cut in segmenter.cuts(words: words, audioEnd: refiner.audioEnd, final: true,
                                           speech: refiner.speechLevel, quiet: refiner.quietest) {
                    if let sentence = refiner.sentence(from: cut.start, to: cut.end) { remaining.append(sentence) }
                }
            }
            guard !remaining.isEmpty else {
                // 等已在处理的句子完成后再给出最终文本。
                refineQueue.async { [self] in
                    queue.async { [self] in
                        completion(transcript.compose(streaming: streamingWords, fallback: streamingText))
                    }
                }
                return
            }
            let group = DispatchGroup()
            for sentence in remaining {
                group.enter()
                refine(sentence, required: true) { group.leave() }
            }
            group.notify(queue: queue) { [self] in
                completion(transcript.compose(streaming: streamingWords, fallback: streamingText))
            }
        }
    }

    private func release(_ duration: Double) {
        lock.lock()
        pendingDuration = max(0, pendingDuration - duration)
        let recovered = backlogWarningActive && pendingDuration <= 2
        if recovered { backlogWarningActive = false }
        lock.unlock()
        if recovered { onWarning?("识别处理已恢复，收声继续。") }
    }
}

enum RecognitionError: LocalizedError {
    case missingModel
    case unsupportedAudio

    var errorDescription: String? {
        switch self {
        case .missingModel: return "找不到英文识别模型，请重新安装完整的课译 App。"
        case .unsupportedAudio: return "麦克风音频格式无法转换为识别所需格式。"
        }
    }
}
