import Foundation

@main
enum Stage4Probe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingyi-stage4-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let glossary = try GlossaryStore(resource: URL(fileURLWithPath: CommandLine.arguments[1]),
                                         customURL: root.appendingPathComponent("custom.json"))
        let expected = ["软件开发": "Kubernetes", "软件工程": "requirements engineering",
                        "数据库": "PostgreSQL", "系统与网络": "TCP handshake"]
        guard glossary.terms.count >= 680,
              expected.allSatisfy({ category, word in
                  glossary.terms.contains { $0.course == category && $0.english == word }
              }),
              glossary.hotwords.contains(where: { $0.lowercased() == "foreign key" }),
              expected.values.allSatisfy({ glossary.hotwords.contains($0) }) else {
            fatalError("Bundled glossary is incomplete")
        }
        try glossary.add(english: "QuartzDB", chinese: "石英数据库")
        guard glossary.hotwords.contains("QuartzDB") else { fatalError("Custom term not saved") }

        let archive = try BilingualArchive(stagingDirectory: root.appendingPathComponent("staging"),
                                           destinationDirectory: root.appendingPathComponent("finished"))
        archive.setEnglish("We use a foreign kay")
        archive.setEnglish("We use a foreign key.")
        archive.setTranslation(segment: 0, seconds: 2.1,
                               english: "We use a foreign key", chinese: "我们使用外键。")
        let done = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        archive.finish(reason: "测试结束") { value in result = value; done.signal() }
        guard done.wait(timeout: .now() + 10) == .success,
              let file = try result?.get() else { fatalError("Archive did not finish") }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard text.contains("We use a foreign key."), !text.contains("foreign kay"),
              text.contains("我们使用外键。") else { fatalError("Archive content is incorrect") }
        print("Glossary: \(glossary.terms.count) terms; bilingual archive: OK")
    }
}
