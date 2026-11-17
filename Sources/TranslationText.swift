import Foundation

/// 送去翻译前清理口语：去掉 um/uh 等填充词和口吃式重复，让机器翻译得到更完整的句子。
/// 只影响翻译输入；屏幕上的英文字幕和保存的英文保持原样。
enum TranslationText {
    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm", "mhm"]
    /// 这些重复在英语里本身是正确的，不合并。
    private static let legitimateRepeats: Set<String> = ["had", "that", "is", "do", "very", "so", "no", "bye", "ha"]

    static func clean(_ text: String) -> String {
        var words: [String] = []
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let word = String(raw)
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if fillers.contains(bare) {
                // 填充词后面的标点（如 “um,”）一并去掉；句末标点挪给前一个词。
                if let last = word.last, ".?!".contains(last), let previous = words.popLast() {
                    words.append(previous.trimmingCharacters(in: CharacterSet(charactersIn: ",")) + String(last))
                }
                continue
            }
            words.append(word)
        }
        // 合并紧挨着的重复：单词（“when when”）和两个词的短语（“we got we got”）。
        var result: [String] = []
        for word in words {
            result.append(word)
            for size in [2, 1] where result.count >= size * 2 {
                let tail = result.suffix(size).map(key)
                let before = result.dropLast(size).suffix(size).map(key)
                guard tail == before, !(size == 1 && legitimateRepeats.contains(tail[0])) else { continue }
                // 保留后一次（它带着句末标点）。
                let kept = Array(result.suffix(size))
                result.removeLast(size * 2)
                result.append(contentsOf: kept)
                break
            }
        }
        let joined = result.joined(separator: " ")
        guard let first = joined.first else { return text }
        return first.uppercased() + joined.dropFirst()
    }

    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
