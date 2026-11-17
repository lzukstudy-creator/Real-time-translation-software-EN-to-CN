import Foundation

struct CaptionLine {
    let english: String
    var chinese: String?
}

struct CaptionTimeline {
    private(set) var lines: [CaptionLine] = []
    /// 标记为重点的句子（行号 → 标记时距开始收声的秒数）。
    private(set) var marks: [Int: Double] = [:]
    static let markSymbol = "★ "

    /// 标记或取消标记最新一句。最新一句太短（老师刚开始说下一句）时连同上一句一起标记。
    /// 返回 true 表示现在是“已标记”。
    @discardableResult
    mutating func toggleLatestMark(seconds: Double) -> Bool {
        guard let last = lines.indices.last else { return false }
        if marks[last] != nil || (last > 0 && marks[last - 1] != nil && Self.wordCount(lines[last].english) < 6) {
            marks[last] = nil
            if last > 0, Self.wordCount(lines[last].english) < 6 { marks[last - 1] = nil }
            return false
        }
        marks[last] = seconds
        if last > 0, Self.wordCount(lines[last].english) < 6 { marks[last - 1] = seconds }
        return true
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    func isMarked(_ index: Int) -> Bool { marks[index] != nil }

    mutating func updateEnglish(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace)
        var segments: [String] = []
        var current: [String] = []
        for word in words {
            current.append(String(word))
            let ended = word.last.map { ".!?".contains($0) } ?? false
            if ended || current.count >= 35 {
                segments.append(current.joined(separator: " "))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { segments.append(current.joined(separator: " ")) }
        marks = marks.filter { $0.key < segments.count }
        lines = segments.enumerated().map { index, english in
            let previous = index < lines.count ? lines[index] : nil
            return CaptionLine(english: english,
                               chinese: previous.map { Self.continuesSameLine($0.english, english) }
                                   == true ? previous?.chinese : nil)
        }
    }

    private static func continuesSameLine(_ old: String, _ new: String) -> Bool {
        if old == new { return true }
        let before = old.lowercased().split(whereSeparator: \.isWhitespace)
        let after = new.lowercased().split(whereSeparator: \.isWhitespace)
        let required = min(2, min(before.count, after.count))
        guard required > 0 else { return false }
        return before.prefix(required).elementsEqual(after.prefix(required))
    }

    @discardableResult
    mutating func applyTranslation(segment: Int, english: String, chinese: String) -> Bool {
        guard lines.indices.contains(segment), lines[segment].english == english else { return false }
        lines[segment].chinese = chinese
        return true
    }

    var displayText: String {
        guard !lines.isEmpty else { return "正在等待讲话…" }
        return lines.enumerated().map { index, line in
            let english = (marks[index] != nil ? Self.markSymbol : "") + line.english
            guard let chinese = line.chinese, !chinese.isEmpty else { return english }
            return "\(english)\n\(chinese)"
        }.joined(separator: "\n\n")
    }
}
