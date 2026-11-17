import AVFoundation
import Foundation

/// 离线评测：同一份 16 kHz 音频按实时节奏切块，分别得到“仅实时识别”和“实时 + 二次精确识别”的结果。
/// Usage: AccuracyProbe STREAM_MODEL REFINE_MODEL WAV [hotwords-file] [score] [paths]
@main
enum AccuracyProbe {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { fputs("usage\n", stderr); exit(2) }
        let stream = URL(fileURLWithPath: args[1])
        let hotwords = args.count > 4 && !args[4].isEmpty
            ? (try String(contentsOfFile: args[4], encoding: .utf8)).split(separator: "\n").map(String.init) : []
        let score = args.count > 5 ? Float(args[5])! : 0.5
        let paths = args.count > 6 ? Int(args[6])! : 2
        let decoder = hotwords.isEmpty ? try StreamingDecoder(model: stream.path)
            : try StreamingDecoder(model: stream.path, contextualTerms: hotwords, paths: paths, score: score)
        let refiner = try SentenceRefiner(model: URL(fileURLWithPath: args[2]),
                                          hotwords: ProcessInfo.processInfo.environment["REFINE_HOTWORDS"] == "1" ? hotwords : [])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[3]))
        var transcript = TwoPassTranscript()
        var segmenter = SentenceSegmenter()
        var pending: [PendingSentence] = []
        var refineSeconds = 0.0, streamSeconds = 0.0, maxSegment = 0.0
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
            try file.read(into: buffer, frameCount: 1600)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let t0 = Date(); let decoded = decoder.feed(samples); streamSeconds += Date().timeIntervalSince(t0)
            refiner.feed(samples)
            if decoded {
                let (_, words, _) = decoder.result()
                for cut in segmenter.cuts(words: words, audioEnd: refiner.audioEnd, speech: refiner.speechLevel, quiet: refiner.quietest) {
                    if let s = refiner.sentence(from: cut.start, to: cut.end) { pending.append(s) }
                }
            }
        }
        decoder.finish()
        let (_, finalWords, _) = decoder.result()
        for cut in segmenter.cuts(words: finalWords, audioEnd: refiner.audioEnd, final: true, speech: refiner.speechLevel, quiet: refiner.quietest) {
            if let s = refiner.sentence(from: cut.start, to: cut.end) { pending.append(s) }
        }
        for sentence in pending {
            let t0 = Date()
            if let segment = refiner.decode(sentence) { transcript.add(segment) }
            let spent = Date().timeIntervalSince(t0)
            refineSeconds += spent; maxSegment = max(maxSegment, spent)
        }
        let (text, words, _) = decoder.result()
        let merged = transcript.compose(streaming: words, fallback: text)
        let audioSeconds = Double(file.length) / 16000
        let report: [String: Any] = [
            "streaming": text, "twoPass": merged, "segments": pending.count,
            "audioSeconds": audioSeconds, "streamRTF": streamSeconds / audioSeconds,
            "refineRTF": refineSeconds / audioSeconds, "refineMaxSegmentSeconds": maxSegment,
            "longestSentence": pending.map { $0.end - $0.start }.max() ?? 0
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
