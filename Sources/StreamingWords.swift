import Foundation

// Reused from Lecture Lens's proven streaming token parser. The App and
// microphone/session lifecycle are independent implementations.
struct WordStamp: Codable, Equatable {
    let text: String
    let start: Double
    let end: Double
}

struct RecognitionEvent: Codable {
    var received: Double
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
    let words: [WordStamp]
    var producedUptime: Double? = nil
    // The earliest word affected by a native hypothesis revision. Optional
    // so reports produced by older versions continue to decode.
    var changedFromWord: Int? = nil
    mutating func receivedAtMainQueue(_ value: Double) { received = value; producedUptime = nil }
}

struct TokenPiece: Equatable { let text: String; let time: Double }

/// Beam search can replace or remove earlier tokens. Rebuild only the word
/// containing the first changed token and its suffix, including punctuation.
/// Callers may pass only the tokens from `offset` onward when every earlier
/// token is known to be final, so each update costs the revisable tail only.
struct StreamingWords {
    private var tokens: [TokenPiece] = []
    private(set) var words: [WordStamp] = []
    private var starts: [Int] = []
    // The words joined by single spaces, maintained with the same suffix edits.
    private var textBytes: [UInt8] = []
    private var textEnds: [Int] = []
    var text: String { String(decoding: textBytes, as: UTF8.self) }
    var tokenCount: Int { tokens.count }

    mutating func accept(_ next: [TokenPiece], from offset: Int = 0) -> ([WordStamp], Int) {
        precondition(offset >= 0 && offset <= tokens.count, "unchanged prefix must already be known")
        let total = offset + next.count
        func piece(_ i: Int) -> TokenPiece { i < offset ? tokens[i] : next[i - offset] }
        var common = offset
        while common < min(tokens.count, total), tokens[common] == next[common - offset] { common += 1 }
        if common == tokens.count && common == total { return (words, words.count) }
        var changed = starts.lastIndex(where: { $0 <= common }) ?? 0
        // A revised token may REMOVE a word boundary: "super key" becomes
        // "superkey". Include the preceding word when the old word's first
        // token now starts with a continuation, rather than retaining a stale
        // split in the display and archive.
        if changed > 0, starts[changed] == common, common < total,
           !piece(common).text.hasPrefix("▁"), piece(common).text.first?.isWhitespace != true {
            changed -= 1
        }
        let begin = starts.isEmpty ? 0 : starts[changed]
        words.removeSubrange(changed...); starts.removeSubrange(changed...)
        var text = "", start = 0.0, end = 0.0, tokenStart = begin
        func append() {
            if !text.isEmpty { words.append(WordStamp(text: text, start: start, end: end)); starts.append(tokenStart) }
        }
        for i in begin..<total {
            let token = piece(i)
            let fragment = token.text.replacingOccurrences(of: "▁", with: " ")
            // NeMo can emit a standalone space-prefixed comma retrospectively.
            // It is punctuation, not a new spoken word with a delivery delay.
            if !fragment.contains(where: { $0.isLetter || $0.isNumber }), !fragment.trimmingCharacters(in: .whitespaces).isEmpty {
                let punctuation = fragment.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { text += punctuation }
                else if let last = words.last {
                    words[words.count - 1] = WordStamp(text: last.text + punctuation, start: last.start, end: last.end)
                    changed = min(changed, words.count - 1)
                }
                continue
            }
            if fragment.first?.isWhitespace == true && !text.isEmpty { append(); text = "" }
            if text.isEmpty { start = token.time; end = start + 0.08; tokenStart = i }
            text += fragment.trimmingCharacters(in: .whitespaces)
            if fragment.contains(where: { $0.isLetter || $0.isNumber }) { end = token.time + 0.08 }
        }
        append()
        tokens.removeSubrange(offset...); tokens.append(contentsOf: next)
        let kept = min(changed, textEnds.count)
        textBytes.removeSubrange((kept == 0 ? 0 : textEnds[kept - 1])...); textEnds.removeSubrange(kept...)
        for word in words[kept...] {
            if !textBytes.isEmpty { textBytes.append(0x20) }
            textBytes.append(contentsOf: word.text.utf8); textEnds.append(textBytes.count)
        }
        return (words, changed)
    }
}

enum RecognitionVocabulary {
    static func phrases(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let text = value.replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            // Do not allow native hotword grammar or control characters into
            // a phrase. Invalid imported entries still remain in the glossary.
            guard !text.isEmpty, text.count <= 120, text.split(separator: " ").count <= 12,
                  text.contains(where: { $0.isLetter || $0.isNumber }),
                  text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " '-.+#".contains($0)) }),
                  seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }.sorted { $0.lowercased() < $1.lowercased() }
    }
}

