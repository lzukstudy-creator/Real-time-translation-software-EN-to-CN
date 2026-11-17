import Foundation

/// 切句与两遍合并的自检（不需要模型）。
@main
enum TwoPassProbe {
    static func main() {
        // 连续讲话：每个词 0.3 秒；每 12 个词是一句（带句号），句后有 0.5 秒真实静音。
        var words: [WordStamp] = []
        var pauses: [ClosedRange<Double>] = []
        var t = 0.0
        for i in 0..<120 {
            let last = i % 12 == 11
            words.append(WordStamp(text: last ? "w\(i)." : "w\(i)", start: t, end: t + 0.3))
            t += 0.35
            if last { pauses.append((t + 0.05)...(t + 0.45)); t += 0.5 }
        }
        // 词间看似有空隙（时间戳），但只有句后才真正安静。
        let quiet: (Double, Double) -> (time: Double, level: Float) = { from, to in
            for pause in pauses where pause.lowerBound < to && pause.upperBound > from {
                return (max(from, pause.lowerBound) + 0.05, 0.01)
            }
            return ((from + to) / 2, 0.9)
        }
        var segmenter = SentenceSegmenter()
        var cuts = segmenter.cuts(words: words, audioEnd: t, speech: 1, quiet: quiet)
        precondition(!cuts.isEmpty, "no sentences cut")
        precondition(cuts.allSatisfy { cut in pauses.contains { $0.contains(cut.end) } }, "cut outside real silence: \(cuts)")
        precondition(cuts.allSatisfy { $0.end - $0.start >= SentenceSegmenter.minimum - 0.01 }, "sentence too short")
        cuts += segmenter.cuts(words: words, audioEnd: t, final: true, speech: 1, quiet: quiet)
        for (a, b) in zip(cuts, cuts.dropFirst()) { precondition(abs(a.end - b.start) < 1e-9, "gap/overlap between sentences") }
        precondition(cuts.last!.end >= words.last!.end, "final flush missed words")

        // 完全没有停顿和标点：必须在 14 秒内强制断开。
        var monotone: [WordStamp] = []
        for i in 0..<120 { monotone.append(WordStamp(text: "m\(i)", start: Double(i) * 0.3, end: Double(i) * 0.3 + 0.28)) }
        var forced = SentenceSegmenter()
        let forcedCuts = forced.cuts(words: monotone, audioEnd: 36, final: true, speech: 1) { from, to in ((from + to) / 2, 0.8) }
        precondition(forcedCuts.count >= 3 && forcedCuts.allSatisfy { $0.end - $0.start <= SentenceSegmenter.maximum + 0.5 },
                     "monotone speech not split: \(forcedCuts)")

        // 合并：精确句子替换它覆盖的实时词，其余实时词按时间保留。
        let stream = [WordStamp(text: "call", start: 0.0, end: 0.3), WordStamp(text: "star", start: 0.4, end: 0.7),
                      WordStamp(text: "frames", start: 0.8, end: 1.1), WordStamp(text: "then", start: 3.0, end: 3.2),
                      WordStamp(text: "more", start: 3.3, end: 3.5)]
        var transcript = TwoPassTranscript()
        transcript.add(RefinedSegment(start: 0, end: 1.3, text: "Call stack frames."))
        let merged = transcript.compose(streaming: stream, fallback: "")
        precondition(merged == "Call stack frames. then more", merged)
        transcript.add(RefinedSegment(start: 2.8, end: 3.7, text: ""))
        precondition(transcript.compose(streaming: stream, fallback: "") == "Call stack frames.", "noise segment kept")
        print("Sentence segmentation and two-pass merge OK")
    }
}
