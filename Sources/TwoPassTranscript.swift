import Foundation

/// 把实时识别的词与第二遍精确识别的句子合成一份字幕：
/// 已经精确识别的时间段用精确结果，其余（还在说的、尚未处理完的）用实时结果。
struct TwoPassTranscript {
    private(set) var refined: [RefinedSegment] = []
    /// 实时词时间戳与音频的允许误差（秒）。
    static let tolerance = 0.15

    var isEmpty: Bool { refined.isEmpty }

    mutating func add(_ segment: RefinedSegment) {
        // 句子几乎总是按时间顺序完成，从末尾向前找插入位置。
        var index = refined.endIndex
        while index > 0, refined[index - 1].start > segment.start { index -= 1 }
        refined.insert(segment, at: index)
    }

    /// 线性合并（词和句子都按时间排序），两小时的课也只需一次遍历。
    func compose(streaming words: [WordStamp], fallback: String) -> String {
        guard !refined.isEmpty else { return fallback }
        var covered = Array(repeating: [String](), count: refined.count)
        var loose: [(time: Double, text: String)] = []
        var segment = 0
        for word in words {
            let center = (word.start + word.end) / 2
            while segment < refined.count, center > refined[segment].end + Self.tolerance { segment += 1 }
            if segment < refined.count, center >= refined[segment].start - Self.tolerance {
                covered[segment].append(word.text)
            } else {
                loose.append((word.start, word.text))
            }
        }
        var pieces: [String] = []
        pieces.reserveCapacity(loose.count + refined.count)
        var next = 0
        for (index, sentence) in refined.enumerated() {
            while next < loose.count, loose[next].time < sentence.start {
                pieces.append(loose[next].text); next += 1
            }
            if !sentence.text.isEmpty {
                pieces.append(sentence.text)
            } else if covered[index].count >= 3 {
                // 精确识别认为是噪声，但实时识别听到了较多词：保留实时结果。
                pieces.append(contentsOf: covered[index])
            }
        }
        while next < loose.count { pieces.append(loose[next].text); next += 1 }
        return pieces.joined(separator: " ")
    }
}
