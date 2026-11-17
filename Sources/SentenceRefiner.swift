import Foundation

/// 一句话说完后，用更准确的离线模型重新识别，修正实时字幕。
struct RefinedSegment: Sendable {
    /// 在整段收声音频中的起止时间（秒），与实时识别的词时间戳同一时间轴。
    let start: Double
    let end: Double
    let text: String
}

/// 切句：候选位置来自实时识别的词边界和标点，但只在音频真正安静的地方下刀。
/// （实时识别的词时间戳是 token 出现的时刻，词间“空隙”不一定是真停顿，直接按它切会把词切断。）
/// 规则：≥4 秒且句末标点处安静就切；≥8 秒时逗号处安静也切；超过 14 秒在后半段最安静的词边界强制切。
struct SentenceSegmenter {
    private(set) var committed = 0.0
    /// 实时识别在这段时间内仍可能修改结果，等它稳定后再切。
    static let settle = 1.8
    static let minimum = 4.0
    static let comfortable = 8.0
    static let maximum = 14.0

    /// quiet(from, to) 返回该时间窗内最安静的位置及其音量；speech 为近期讲话的典型音量。
    mutating func cuts(words: [WordStamp], audioEnd: Double, final: Bool = false,
                       speech: Float, quiet: (Double, Double) -> (time: Double, level: Float))
        -> [(start: Double, end: Double)] {
        let stableUntil = final ? Double.infinity : audioEnd - Self.settle
        var index = words.firstIndex { ($0.start + $0.end) / 2 >= committed } ?? words.endIndex
        var result: [(start: Double, end: Double)] = []
        while index < words.count, words[index].end <= stableUntil {
            let segmentStart = committed
            var chosen: Double?
            var forced: (time: Double, ratio: Float)?
            var hitMaximum = false
            var i = index
            while i < words.count, words[i].end <= stableUntil {
                let word = words[i]
                let length = word.end - segmentStart
                if length > Self.maximum { hitMaximum = true; break }
                let hasNext = i + 1 < words.count
                guard hasNext || final else { break }
                let nextStart = hasNext ? words[i + 1].start : min(audioEnd, word.end + 0.6)
                guard !hasNext || words[i + 1].start <= stableUntil + 1 else { break }
                let window = quiet(word.end, max(word.end + 0.25, nextStart + 0.1))
                let ratio = speech > 0 ? window.level / speech : 0
                let mark = word.text.last
                let sentenceEnd = mark.map { ".?!".contains($0) } ?? false
                let clauseEnd = mark.map { ",;:".contains($0) } ?? false
                if length >= Self.minimum, sentenceEnd, ratio < 0.5 { chosen = window.time; break }
                if length >= Self.comfortable, clauseEnd || sentenceEnd, ratio < 0.35 { chosen = window.time; break }
                if length >= Self.comfortable, ratio < 0.12 { chosen = window.time; break }
                if length >= Self.maximum / 2, forced == nil || ratio < forced!.ratio {
                    forced = (window.time, ratio)
                }
                i += 1
            }
            if chosen == nil, hitMaximum { chosen = forced?.time ?? words[max(index, i - 1)].end + 0.1 }
            if chosen == nil, final {
                chosen = (words.last.map { $0.end + 0.6 } ?? segmentStart)
                index = words.count
            }
            guard let cut = chosen, cut > segmentStart else { break }
            result.append((segmentStart, cut))
            committed = cut
            index = words.firstIndex { ($0.start + $0.end) / 2 >= cut } ?? words.endIndex
        }
        return result
    }
}

/// 第二遍识别：Parakeet TDT 0.6B v2（离线、带标点和大小写）重新识别每一句。
/// 不线程安全：feed/sentence 在识别队列上调用，decode 在单独的低优先级队列上调用。
final class SentenceRefiner {
    static let sampleRate = 16000
    private let recognizer: OpaquePointer
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private let hotwords: String?
    /// 最近一段原始音频（与实时识别同一时间轴），切句时从这里取。
    private var history: [Float] = []
    private var historyStart = 0
    private static let historyLimit = 60 * sampleRate
    var audioEnd: Double { Double(historyStart + history.count) / Double(Self.sampleRate) }

    init(model: URL, hotwords: [String] = [], threads: Int = 2) throws {
        var pool: [UnsafeMutablePointer<CChar>] = []
        var retained = false
        defer { if !retained { for p in pool { free(p) } } }
        func c(_ text: String) -> UnsafePointer<CChar> { let p = strdup(text)!; pool.append(p); return UnsafePointer(p) }
        let required = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: model.appendingPathComponent($0).path) }) else {
            throw RecognitionError.missingModel
        }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(Self.sampleRate)
        config.feat_config.feature_dim = 80
        let path = model.path
        config.model_config.transducer.encoder = c(path + "/encoder.int8.onnx")
        config.model_config.transducer.decoder = c(path + "/decoder.int8.onnx")
        config.model_config.transducer.joiner = c(path + "/joiner.int8.onnx")
        config.model_config.tokens = c(path + "/tokens.txt")
        config.model_config.model_type = c("nemo_transducer")
        config.model_config.num_threads = Int32(max(1, min(threads, 4)))
        config.model_config.provider = c("cpu")
        config.decoding_method = c(hotwords.isEmpty ? "greedy_search" : "modified_beam_search")
        config.max_active_paths = 4
        if !hotwords.isEmpty {
            config.model_config.modeling_unit = c("bpe")
            config.hotwords_score = 1.0
        }
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw NSError(domain: "refiner", code: 1)
        }
        self.recognizer = recognizer
        self.hotwords = hotwords.isEmpty ? nil : hotwords.joined(separator: "\n")
        strings = pool
        retained = true
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        for p in strings { free(p) }
    }

    /// 送入与实时识别完全相同的 16 kHz 样本。
    func feed(_ samples: [Float]) {
        history.append(contentsOf: samples)
        if history.count > Self.historyLimit {
            let drop = history.count - Self.historyLimit
            history.removeFirst(drop)
            historyStart += drop
        }
    }

    /// 时间窗内最安静的 30 毫秒（步长 10 毫秒）的中心时间和音量。
    func quietest(from start: Double, to end: Double) -> (time: Double, level: Float) {
        let frame = Self.sampleRate * 3 / 100, hop = Self.sampleRate / 100
        let from = max(historyStart, Int(start * Double(Self.sampleRate)))
        let to = min(historyStart + history.count, Int(end * Double(Self.sampleRate)))
        var best = (time: (start + end) / 2, level: Float.greatestFiniteMagnitude)
        var position = from
        while position + frame <= to {
            let offset = position - historyStart
            var sum: Float = 0
            for k in offset..<(offset + frame) { sum += history[k] * history[k] }
            let level = (sum / Float(frame)).squareRoot()
            if level < best.level {
                best = (Double(position + frame / 2) / Double(Self.sampleRate), level)
            }
            position += hop
        }
        return best.level == .greatestFiniteMagnitude ? (best.time, 0) : best
    }

    /// 最近 10 秒里讲话的典型音量（30 毫秒帧 RMS 的第 70 百分位）。
    var speechLevel: Float {
        let frame = Self.sampleRate * 3 / 100
        let span = min(history.count, 10 * Self.sampleRate)
        guard span >= frame * 10 else { return 0 }
        var levels: [Float] = []
        levels.reserveCapacity(span / frame)
        var position = history.count - span
        while position + frame <= history.count {
            var sum: Float = 0
            for k in position..<(position + frame) { sum += history[k] * history[k] }
            levels.append((sum / Float(frame)).squareRoot())
            position += frame
        }
        levels.sort()
        return levels[levels.count * 7 / 10]
    }

    /// 取出一句的音频（秒）。已经超出保留范围的部分会被裁掉。
    func sentence(from start: Double, to end: Double) -> PendingSentence? {
        let from = max(historyStart, Int(start * Double(Self.sampleRate)))
        let to = min(historyStart + history.count, Int(end * Double(Self.sampleRate)))
        guard to - from >= Self.sampleRate / 4 else { return nil }
        return PendingSentence(start: start, end: end,
                               samples: Array(history[(from - historyStart)..<(to - historyStart)]))
    }

    /// 重新识别一句话。较安静的录音先统一音量（模型对过小的输入不敏感）。
    func decode(_ sentence: PendingSentence) -> RefinedSegment? {
        var samples = sentence.samples
        Self.normalizeLoudness(&samples)
        let stream: OpaquePointer?
        if let hotwords {
            stream = hotwords.withCString { SherpaOnnxCreateOfflineStreamWithHotwords(recognizer, $0) }
        } else {
            stream = SherpaOnnxCreateOfflineStream(recognizer)
        }
        guard let stream else { return nil }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return nil }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let text = result.pointee.text.map { String(cString: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RefinedSegment(start: sentence.start, end: sentence.end, text: text)
    }

    /// 把语音 RMS 调到约 -20 dBFS，最多放大 30 dB，并防止削波。
    static func normalizeLoudness(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        var peak: Float = 0
        for value in samples {
            sum += value * value
            peak = max(peak, abs(value))
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 1e-5, peak > 0 else { return }
        let gain = min(0.1 / rms, 31.6, 0.97 / peak)
        guard gain > 1.05 else { return }
        for index in samples.indices { samples[index] *= gain }
    }
}

struct PendingSentence: @unchecked Sendable {
    let start: Double
    let end: Double
    let samples: [Float]
}
