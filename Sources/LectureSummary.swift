import Foundation

/// 课后总结（本机、离线）。
///
/// 思路：讲课录音转成的字幕很口语化，直接挑“词频最高”的句子会挑出重复啰嗦的话。
/// 这里综合四种信号给每句打分，再按讲课顺序分段、在每段挑代表句，并去掉意思重复的句子：
/// 1. 中心度：与全文主题（TF-IDF 质心）越接近越重要；
/// 2. 强调语：老师说 “important / remember / the key point / in summary / exam …” 的句子；
/// 3. 术语：包含术语表里的专业词；
/// 4. 学生标记：上课时按 ⌘B 标为重点的句子优先。
enum LectureSummary {
    struct Line {
        let start: Double
        let english: String
        let chinese: String?
        let marked: Bool
    }

    static let title = "演讲总结"

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "because", "been", "but", "by", "can", "could",
        "do", "does", "for", "from", "get", "got", "going", "gonna", "has", "have", "how", "i", "if",
        "in", "into", "is", "it", "its", "just", "kind", "know", "like", "lot", "me", "more", "my",
        "of", "ok", "okay", "on", "one", "or", "our", "really", "right", "say", "see", "so", "some",
        "sort", "that", "the", "their", "then", "there", "these", "they", "thing", "things", "think",
        "this", "those", "to", "um", "uh", "up", "us", "very", "want", "was", "way", "we", "well",
        "were", "what", "when", "where", "which", "who", "will", "with", "would", "yeah", "you",
        "your", "them", "all", "about", "also", "now", "here", "go", "actually", "basically"
    ]

    /// 老师强调重点时常用的说法。
    private static let cues: [(phrase: String, weight: Double)] = [
        ("important", 1.0), ("key point", 1.2), ("the key", 0.8), ("remember", 1.0), ("make sure", 0.7),
        ("in summary", 1.2), ("to summarize", 1.2), ("in conclusion", 1.2), ("the main", 0.7),
        ("exam", 1.2), ("assessment", 0.9), ("coursework", 0.8), ("deadline", 0.9), ("assignment", 0.8),
        ("is called", 0.9), ("is defined", 1.0), ("definition", 1.0), ("we define", 1.0), ("means that", 0.6),
        ("the difference between", 0.9), ("for example", 0.3), ("you need to", 0.6), ("you must", 0.8),
        ("don't forget", 0.9), ("crucial", 1.0), ("essential", 0.8), ("the point is", 1.0),
        ("next week", 0.6), ("take away", 0.8), ("takeaway", 0.8)
    ]

    static func make(lines: [Line], terms: [(english: String, chinese: String)] = []) -> String? {
        let usable = lines.enumerated().filter { _, line in
            guard let chinese = line.chinese?.trimmingCharacters(in: .whitespacesAndNewlines), !chinese.isEmpty
            else { return false }
            return words(line.english).count >= 5 || line.marked
        }
        guard !usable.isEmpty else { return nil }

        // TF-IDF 向量
        let tokens = usable.map { words($0.element.english) }
        var frequency: [String: Int] = [:]
        for set in tokens.map(Set.init) { for word in set { frequency[word, default: 0] += 1 } }
        let count = Double(tokens.count)
        let vectors: [[String: Double]] = tokens.map { list in
            var tf: [String: Double] = [:]
            for word in list { tf[word, default: 0] += 1 }
            var vector: [String: Double] = [:]
            for (word, value) in tf {
                vector[word] = value * log(1 + count / Double(frequency[word] ?? 1))
            }
            return normalized(vector)
        }
        var centroid: [String: Double] = [:]
        for vector in vectors { for (word, value) in vector { centroid[word, default: 0] += value } }
        centroid = normalized(centroid)

        let termNames = terms.map { $0.english.lowercased() }
        let scores: [Double] = usable.indices.map { index in
            let line = usable[index].element
            let lower = line.english.lowercased()
            let centrality = dot(vectors[index], centroid)
            let cue = cues.reduce(0.0) { lower.contains($1.phrase) ? $0 + $1.weight : $0 }
            let termHits = Double(termNames.filter { lower.contains($0) }.count)
            let length = Double(tokens[index].count)
            // 太短的句子信息少，太长的通常是没断开的口语流水句。
            let lengthFactor = length < 8 ? 0.7 : (length > 45 ? 0.8 : 1.0)
            // 口头禅越多，越像随口的过渡话，降低分数。
            let raw = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
            let fillers = raw.filter { ["um", "uh", "okay", "ok", "so", "like", "yeah", "right", "erm"].contains($0) }.count
            let fluency = max(0.35, 1 - 2.5 * Double(fillers) / Double(max(1, raw.count)))
            return (centrality * 2 + min(cue, 2) * 0.6 + min(termHits, 3) * 0.35 + (line.marked ? 3 : 0)) * lengthFactor * fluency
        }

        // 本节主线：按时间分成若干段，每段挑一个代表句（与已选句子意思重复的跳过）。
        let sections = max(2, min(6, usable.count / 20 + 2))
        var outline: [Int] = []
        for section in 0..<min(sections, usable.count) {
            let range = (section * usable.count / sections)..<((section + 1) * usable.count / sections)
            let candidates = range.sorted { scores[$0] > scores[$1] }
            if let pick = candidates.first(where: { candidate in
                !outline.contains { dot(vectors[$0], vectors[candidate]) > 0.5 }
            }) {
                outline.append(pick)
            }
        }

        // 重点：学生标记的句子全部保留，再按分数补充（同样去重），最多 6 条。
        var key: [Int] = usable.indices.filter { usable[$0].element.marked }
        for candidate in usable.indices.sorted(by: { scores[$0] > scores[$1] }) where key.count < 6 {
            guard !key.contains(candidate), !outline.contains(candidate),
                  !key.contains(where: { dot(vectors[$0], vectors[candidate]) > 0.5 }) else { continue }
            let lower = usable[candidate].element.english.lowercased()
            // 补充重点只收“有强调语或术语”的句子，避免随便凑数。
            guard cues.contains(where: { lower.contains($0.phrase) }) || termNames.contains(where: { lower.contains($0) })
            else { continue }
            key.append(candidate)
        }
        key.sort()

        // 核心内容：综合得分最高、且互不重复的两句，按时间排列。
        var core: [Int] = []
        for candidate in usable.indices.sorted(by: { scores[$0] > scores[$1] }) where core.count < 2 {
            if !core.contains(where: { dot(vectors[$0], vectors[candidate]) > 0.4 }) { core.append(candidate) }
        }
        core.sort()

        func chinese(_ index: Int) -> String { cleanChinese(usable[index].element.chinese ?? "") }
        var text = "\(title)（本机根据字幕提取）\n"
        text += "核心内容\n" + core.map(chinese).joined(separator: " ") + "\n"
        text += "\n本节主线\n"
        for (number, index) in outline.enumerated() {
            text += "\(number + 1). [\(clock(usable[index].element.start))] \(chinese(index))\n"
        }
        if !key.isEmpty {
            text += "\n重点\n"
            for index in key {
                text += (usable[index].element.marked ? "★ " : "• ") + chinese(index) + "\n"
            }
        }
        if !terms.isEmpty {
            text += "\n本节术语\n"
            for term in terms.prefix(12) { text += "• \(term.english)：\(term.chinese)\n" }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 兼容旧接口：没有时间与标记信息时使用。
    static func make(from lines: [CaptionLine]) -> String? {
        make(lines: lines.map { Line(start: 0, english: $0.english, chinese: $0.chinese, marked: false) })
    }

    /// 去掉译文里的口头禅（嗯、呃、啊）。
    static func cleanChinese(_ text: String) -> String {
        var result = text
        for filler in ["嗯，", "呃，", "啊，", "嗯", "呃"] { result = result.replacingOccurrences(of: filler, with: "") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "，, "))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    private static func normalized(_ vector: [String: Double]) -> [String: Double] {
        let length = sqrt(vector.values.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return vector }
        return vector.mapValues { $0 / length }
    }

    private static func dot(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let (small, large) = a.count < b.count ? (a, b) : (b, a)
        return small.reduce(0) { $0 + $1.value * (large[$1.key] ?? 0) }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
