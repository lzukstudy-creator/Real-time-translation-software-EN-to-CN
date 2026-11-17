import Foundation

struct CaptionLine {
    let english: String
    var chinese: String?
}

struct CaptionTimeline {
    private(set) var lines: [CaptionLine] = []

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
        return lines.map { line in
            guard let chinese = line.chinese, !chinese.isEmpty else { return line.english }
            return "\(line.english)\n\(chinese)"
        }.joined(separator: "\n\n")
    }
}
