import Foundation

// Reused, source-limited course terminology matching from Lecture Lens.
struct Term: Codable, Identifiable, Equatable {
    var id: String { course.lowercased() + "|" + english.lowercased() }
    var english: String
    var chinese: String
    var explanation: String
    var course: String
    var source: String? = nil
    var references: [TermReference]? = nil
}

struct TermReference: Codable, Equatable {
    var file: String
    var page: Int
    var path: String
    var relative: String
    var sha256: String
    var format: String
}

struct CourseInfo: Codable, Identifiable {
    var id: String
    var title: String
    var scope: String
    var source: String
}

struct CoursePack: Codable {
    var version: Int
    var verifiedOn: String
    var courses: [CourseInfo]
    var terms: [Term]
}

enum Glossary {
    private static var patterns: [String: NSRegularExpression] = [:]
    private static let patternLock = NSLock()

    static func regex(_ english: String) -> NSRegularExpression {
        patternLock.lock(); defer { patternLock.unlock() }
        let key = english.lowercased()
        if let cached = patterns[key] { return cached }
        var parts = english.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐‑–—"))).filter { !$0.isEmpty }
        if parts.isEmpty { return try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: english), options: .caseInsensitive) }
        let last = parts.removeLast()
        var escaped = parts.map(NSRegularExpression.escapedPattern(for:))
        if last.lowercased().range(of: "[bcdfghjklmnpqrstvwxyz]y$", options: .regularExpression) != nil {
            escaped.append(NSRegularExpression.escapedPattern(for: String(last.dropLast())) + "(?:y|ies)")
        } else {
            escaped.append(NSRegularExpression.escapedPattern(for: last) + (last.lowercased().hasSuffix("s") ? "" : "(?:s|es)?"))
        }
        let regex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_-])" + escaped.joined(separator: "[\\s‐‑–—-]+") + "(?![\\p{L}\\p{N}_-])", options: .caseInsensitive)
        if patterns.count > 2048 { patterns.removeAll(keepingCapacity: true) }
        patterns[key] = regex
        return regex
    }

    static func range(_ english: String, in text: String) -> NSRange? {
        regex(english).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).last?.range
    }

    static func matches(in text: String, terms: [Term], known: Set<String>) -> [Term] {
        terms.filter { term in
            !known.contains(term.id) && !known.contains(term.english.lowercased()) && range(term.english, in: text) != nil
        }.sorted { $0.english.count > $1.english.count }
    }
}

/// Local, source-tagged vocabulary detection. Context cues resolve conflicts;
/// common English words require nearby technical evidence before being hinted.
enum AutomaticTerms {
    private static let anchors: [String: [(String, Double)]] = [
        "4039": [("Python", 6), ("NumPy", 6), ("Stepper", 7), ("Gatherer", 7), ("sentinel value", 6), ("f-string", 6), ("readline", 5), ("dictionary", 3), ("while loop", 3), ("for loop", 3), ("variable", 1)],
        "4043": [("Sigma16", 8), ("Sigma 16", 8), ("assembly language", 7), ("opcode", 6), ("program counter", 6), ("register", 4), ("ALU", 6), ("CPU", 5), ("binary", 3), ("bus", 2), ("word size", 5), ("page table", 5), ("interrupt", 4), ("operating system", 5)],
        "5018P": [("dissertation", 8), ("viva", 8), ("supervisor", 6), ("project scope", 4), ("literature review", 6), ("deliverable", 3), ("MVP", 4), ("project", 1)],
        "5059": [("Scrum", 8), ("sprint", 5), ("user story", 6), ("Kanban", 8), ("agile", 3), ("coupling", 6), ("cohesion", 6), ("UML", 4), ("class diagram", 5), ("design pattern", 5), ("refactoring", 6), ("inheritance", 3), ("polymorphism", 5), ("Java", 4), ("JUnit", 6)],
        "5076": [("relational", 5), ("database", 2), ("DBMS", 4), ("SQL", 5), ("entity", 2), ("tuple", 2), ("primary key", 6), ("foreign key", 6), ("superkey", 7), ("referential integrity", 7), ("schema", 3), ("attribute", 1)],
        "5077": [("IaaS", 7), ("PaaS", 7), ("SaaS", 6), ("zero trust", 8), ("shadow IT", 8), ("legacy system", 4), ("enterprise architecture", 7), ("public cloud", 5), ("private cloud", 5), ("cloud bursting", 8), ("attack", 2), ("audit log", 4), ("perimeter", 4)]
    ]
    private static let common: Set<String> = ["class", "object", "word", "state", "pattern", "process", "thread", "function", "value", "key", "reference", "scope", "comment", "file", "range", "import", "set", "try", "with", "split", "strip", "instance", "method", "static", "address", "page", "bus", "memory", "digital", "binary", "signed", "unsigned", "fetch", "decode", "execute", "label", "branch", "jump", "client", "server", "constraint", "conceptual", "relationship", "relation", "attribute", "entity", "domain", "abstract", "boundary", "strategy", "command", "factory", "observer", "composite", "interface", "component", "dependency", "visibility", "increment", "iteration", "requirement", "evaluation", "citation", "repository", "commit"]

    private static func scores(_ text: String) -> [(String, Double)] {
        anchors.map { course, cues in
            (course, cues.reduce(0) { $0 + (Glossary.range($1.0, in: text) == nil ? 0 : $1.1) })
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }
    private static func best(_ scores: [(String, Double)]) -> String? {
        guard let first = scores.first, first.1 >= 5, first.1 - (scores.dropFirst().first?.1 ?? 0) >= 2 else { return nil }
        return first.0
    }
    static func detect(in visible: String, context: String, terms: [Term], known: Set<String>) -> [Term] {
        let globalScores = scores(String(context.suffix(1400)))
        let source = visible as NSString
        let matches = Glossary.matches(in: visible, terms: terms, known: known)
        let groups = Dictionary(grouping: matches, by: { $0.english.lowercased().replacingOccurrences(of: "-", with: " ") })
        var chosen: [(Term, NSRange)] = []
        for group in groups.values {
            guard let first = group.first, let range = Glossary.range(first.english, in: visible) else { continue }
            let start = max(0, range.location - 150), end = min(source.length, NSMaxRange(range) + 150)
            let near = source.substring(with: NSRange(location: start, length: end - start))
            let localScores = scores(near)
            let inferred = best(localScores) ?? best(globalScores)
            let meanings = Set(group.map(\.chinese))
            let term: Term
            if let inferred, let scoped = group.first(where: { $0.course == inferred }) { term = scoped }
            else if meanings.count == 1 { term = first }
            else { continue }
            let key = term.english.lowercased()
            if common.contains(key) {
                guard (localScores.first(where: { $0.0 == term.course })?.1 ?? 0) >= 5 ||
                        (inferred == term.course && (globalScores.first(where: { $0.0 == term.course })?.1 ?? 0) >= 8) else { continue }
            }
            let lower = near.lowercased()
            let after = source.substring(from: NSMaxRange(range)).lowercased()
            if key == "class" && after.range(of: "^\\s+(?:we|you|i|today|tomorrow|students|will|is over)\\b", options: .regularExpression) != nil { continue }
            if key == "word" && lower.range(of: "bits?|bytes?|cpu|register|word size|machine", options: .regularExpression) == nil { continue }
            if key == "bit" && after.range(of: "^\\s+(?:more|less|of|harder|easier|better|different|like|about)\\b", options: .regularExpression) != nil { continue }
            if key == "key" && after.range(of: "^\\s+(?:point|idea|thing|difference|part|concept|way|question|factor)s?\\b", options: .regularExpression) != nil { continue }
            if key == "abstract" && lower.range(of: "summary|title|dissertation|paper|thesis|acknowledg|table of contents", options: .regularExpression) == nil { continue }
            if key == "page" && lower.range(of: "memory|mmu|virtual|paging|frame|page fault", options: .regularExpression) == nil { continue }
            if key == "bus" && lower.range(of: "bits?|wires?|cpu|computer|register|hardware|parallel", options: .regularExpression) == nil { continue }
            if key == "try" || key == "with" { continue }
            chosen.append((term, range))
        }
        // A longer phrase consumes its component word: candidate key beats key.
        chosen = chosen.filter { item in
            !chosen.contains { other in other.1.length > item.1.length && other.1.location <= item.1.location && NSMaxRange(other.1) >= NSMaxRange(item.1) }
        }.sorted { NSMaxRange($0.1) == NSMaxRange($1.1) ? $0.1.length > $1.1.length : NSMaxRange($0.1) > NSMaxRange($1.1) }
        var meanings: Set<String> = []
        return Array(chosen.map(\.0).filter { meanings.insert($0.chinese).inserted }.prefix(4))
    }
}
