import Foundation

enum LectureSummary {
    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "because", "been", "but", "by",
        "can", "do", "for", "from", "has", "have", "how", "i", "if", "in", "into",
        "is", "it", "its", "of", "on", "or", "our", "so", "that", "the", "their",
        "there", "these", "this", "those", "to", "we", "what", "when", "which",
        "with", "you", "your", "will", "would", "was", "were", "they", "them"
    ]

    static func make(from lines: [CaptionLine]) -> String? {
        let translated = lines.compactMap { line -> CaptionLine? in
            guard let chinese = line.chinese?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !chinese.isEmpty, !line.english.isEmpty else { return nil }
            return CaptionLine(english: line.english, chinese: chinese)
        }
        guard !translated.isEmpty else { return nil }

        let wordSets = translated.map { line in
            Set(line.english.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !stopwords.contains($0) })
        }
        var documentFrequency: [String: Int] = [:]
        for words in wordSets {
            for word in words { documentFrequency[word, default: 0] += 1 }
        }
        let scores = wordSets.enumerated().map { index, words in
            let topicScore = words.reduce(0.0) { total, word in
                total + log1p(Double(documentFrequency[word, default: 0]))
            }
            return topicScore / sqrt(Double(max(1, words.count))) +
                (index < max(1, translated.count / 5) ? 0.25 : 0)
        }
        let ranked = translated.indices.sorted {
            scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1]
        }
        let overview = Array(ranked.prefix(min(2, translated.count))).sorted()
            .compactMap { translated[$0].chinese }.joined(separator: " ")

        let keyIndices: [Int]
        if translated.count > 20 {
            keyIndices = (0..<4).compactMap { section in
                let start = section * translated.count / 4
                let end = (section + 1) * translated.count / 4
                return (start..<end).max { scores[$0] < scores[$1] }
            }
        } else {
            keyIndices = Array(ranked.prefix(min(3, translated.count))).sorted()
        }
        let points = keyIndices.enumerated().compactMap { number, index -> String? in
            guard let chinese = translated[index].chinese else { return nil }
            return "\(number + 1). \(chinese)"
        }.joined(separator: "\n")
        return "演讲总结（依据字幕自动提取）\n整体内容\n\(overview)\n\n重点\n\(points)"
    }
}
