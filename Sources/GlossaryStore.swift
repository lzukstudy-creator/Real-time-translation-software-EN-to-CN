import Foundation

final class GlossaryStore {
    private let bundled: [Term]
    private let supplemental: [Term]
    private let customURL: URL
    private var custom: [Term]
    private(set) var terms: [Term] = []

    var hotwords: [String] { RecognitionVocabulary.phrases(terms.map(\.english)) }

    init(resource: URL, customURL: URL) throws {
        let data = try Data(contentsOf: resource)
        bundled = try JSONDecoder().decode(CoursePack.self, from: data).terms
        supplemental = try Self.loadSupplemental(
            resource.deletingLastPathComponent().appendingPathComponent("technical-terms.tsv"))
        self.customURL = customURL
        if let saved = try? Data(contentsOf: customURL),
           let decoded = try? JSONDecoder().decode([Term].self, from: saved) {
            custom = decoded
        } else {
            custom = []
        }
        rebuildTerms()
    }

    func suggestions(in visible: String, context: String) -> [Term] {
        AutomaticTerms.detect(in: visible, context: context, terms: terms, known: [])
    }

    func add(english: String, chinese: String, explanation: String = "", source: String = "手动添加") throws {
        let english = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let chinese = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !english.isEmpty, !chinese.isEmpty else { throw GlossaryError.emptyTerm }
        let term = Term(english: english, chinese: chinese,
                        explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines),
                        course: "General", source: source)
        custom.removeAll { $0.id == term.id }
        custom.append(term)
        try save()
        rebuildTerms()
    }

    func importTSV(_ url: URL) throws -> Int {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#")
        }
        guard lines.count <= 1000 else { throw GlossaryError.tooManyTerms }
        var imported: [Term] = []
        for (index, line) in lines.enumerated() {
            let fields = line.components(separatedBy: "\t").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty,
                  fields[0].count <= 120, fields[1].count <= 200 else {
                throw GlossaryError.invalidLine(index + 1)
            }
            imported.append(Term(english: fields[0], chinese: fields[1],
                                 explanation: fields.count > 2 ? fields[2] : "",
                                 course: "General", source: "导入：\(url.lastPathComponent)"))
        }
        for term in imported {
            custom.removeAll { $0.id == term.id }
            custom.append(term)
        }
        try save()
        rebuildTerms()
        return imported.count
    }

    private func rebuildTerms() {
        var byID: [String: Term] = [:]
        for term in bundled { byID[term.id] = term }
        for term in supplemental { byID[term.id] = term }
        for term in custom { byID[term.id] = term }
        // 课件词表里可能有繁体译名，显示前统一成简体。
        terms = byID.values.map { term in
            var term = term
            term.chinese = Self.simplified(term.chinese)
            return term
        }.sorted {
            let order = $0.english.localizedCaseInsensitiveCompare($1.english)
            return order == .orderedSame ? $0.course < $1.course : order == .orderedAscending
        }
    }

    private static func simplified(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x3400 }) else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }

    private static func loadSupplemental(_ url: URL) throws -> [Term] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let categories: Set<String> = ["软件开发", "软件工程", "数据库", "系统与网络"]
        var seen: Set<String> = []
        var results: [Term] = []
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = line.components(separatedBy: "\t").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard fields.count == 3, categories.contains(fields[0]), !fields[1].isEmpty,
                  !fields[2].isEmpty, RecognitionVocabulary.phrases([fields[1]]).count == 1,
                  seen.insert(fields[1].lowercased()).inserted else {
                throw GlossaryError.invalidBundledTerm(index + 1)
            }
            results.append(Term(english: fields[1], chinese: fields[2], explanation: "",
                                course: fields[0], source: "内置通用技术术语（非课件引文）"))
        }
        return results
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: customURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(custom).write(to: customURL, options: .atomic)
    }
}

enum GlossaryError: LocalizedError {
    case emptyTerm
    case tooManyTerms
    case invalidLine(Int)
    case invalidBundledTerm(Int)

    var errorDescription: String? {
        switch self {
        case .emptyTerm: return "英文术语和中文释义都不能为空。"
        case .tooManyTerms: return "一次最多导入 1000 条术语。"
        case .invalidLine(let line): return "第 \(line) 行格式不正确；请用 Tab 分隔英文和中文。"
        case .invalidBundledTerm(let line): return "内置技术术语第 \(line) 行格式不正确。"
        }
    }
}
