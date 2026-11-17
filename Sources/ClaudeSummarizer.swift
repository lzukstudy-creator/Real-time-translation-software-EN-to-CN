import Foundation

/// 用本机的 Claude Code 生成课后总结，消耗的是用户自己的 Claude 订阅额度。
///
/// 为了确保不产生额外费用：启动 Claude Code 前清除 ANTHROPIC_API_KEY 等环境变量，
/// 让它只能使用登录的 Claude 账号（订阅），不会走按量付费的 API。
/// 同时关闭所有工具、MCP 和项目设置，它只能读入字幕文字并输出总结。
enum ClaudeSummarizer {
    enum Failure: LocalizedError {
        case notInstalled, notLoggedIn, timedOut, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "没有找到 Claude Code。"
            case .notLoggedIn: return "Claude Code 还没有登录。"
            case .timedOut: return "Claude 总结超时。"
            case .failed(let message): return message
            }
        }
    }

    static let preferenceKey = "TingYiClaudeSummary"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }

    /// 依次查找官方安装位置和 Claude 桌面版自带的 Claude Code（取最新版本）。
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixed = [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0) }
            + ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"].map(URL.init(fileURLWithPath:))
        if let found = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        let bundled = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: bundled.path)) ?? []
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let builds = (try? FileManager.default.contentsOfDirectory(atPath: bundled.appendingPathComponent(version).path)) ?? []
            for build in builds {
                let binary = bundled.appendingPathComponent("\(version)/\(build)/claude.app/Contents/MacOS/claude")
                if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
        return nil
    }

    private static let systemPrompt = """
    你是大学课堂的笔记助手。用户会给你一节英文课的实时语音识别字幕（带时间，可能有识别错误），\
    以及学生上课时标记的重点（★）和本节出现的术语。请写一份给中国留学生复习用的中文课后总结。

    要求：
    - 只根据字幕内容总结，不要编造字幕里没有的知识点；拿不准的内容宁可不写。
    - 字幕有明显识别错误时，按上下文纠正后再理解（例如 "call star" 应为 "call stack"）。
    - 学生标记的 ★ 句子必须体现在“重点”里。
    - 老师提到的作业、考试、截止日期、下节课安排等事务信息一定要写进“重点”。
    - 专业词第一次出现时用“中文（English）”的形式。
    - 输出纯文本，不要使用 Markdown 符号（不要 #、**、表格），严格按下面的格式：

    演讲总结（Claude 生成）
    核心内容
    用 2～3 句话概括这节课讲了什么、要解决什么问题。

    本节主线
    1. [时间] 按讲课顺序写 3～6 条，每条一句话说清这一部分讲了什么。

    重点
    ★ 或 • 开头，写 3～6 条最值得记住的定义、结论、方法或老师强调的内容。

    本节术语
    • English：中文——一句话解释（最多 10 条，只列真正重要的）
    """

    /// 在后台运行，完成后在主线程回调。
    static func summarize(lines: [LectureSummary.Line], terms: [(english: String, chinese: String)],
                          completion: @escaping (Result<String, Error>) -> Void) {
        guard let executable = locate() else {
            DispatchQueue.main.async { completion(.failure(Failure.notInstalled)) }
            return
        }
        var input = "以下是本节课的字幕（[分:秒] 英文，★ 为学生标记的重点）：\n\n"
        for line in lines {
            let total = Int(max(0, line.start))
            input += String(format: "[%02d:%02d] ", total / 60, total % 60)
            input += (line.marked ? "★ " : "") + TranslationText.clean(line.english) + "\n"
        }
        if !terms.isEmpty {
            input += "\n本节出现的术语：" + terms.map { "\($0.english)（\($0.chinese)）" }.joined(separator: "、") + "\n"
        }
        if input.count > 150_000 { input = String(input.prefix(150_000)) + "\n（字幕过长，已截断）\n" }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-p", "--model", "sonnet", "--output-format", "json",
                                 "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                                 "--no-session-persistence", "--system-prompt", systemPrompt]
            var environment = ProcessInfo.processInfo.environment
            for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDECODE",
                        "CLAUDE_CODE_ENTRYPOINT"] {
                environment[key] = nil
            }
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: timer)
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let result: Result<String, Error>
            if process.terminationReason == .uncaughtSignal {
                result = .failure(Failure.timedOut)
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["result"] as? String {
                if (json["is_error"] as? Bool) == true {
                    result = .failure(text.localizedCaseInsensitiveContains("not logged in")
                                      ? Failure.notLoggedIn : Failure.failed(text))
                } else {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = trimmed.contains("重点") ? .success(trimmed) : .failure(Failure.failed("Claude 返回的总结格式不完整。"))
                }
            } else {
                result = .failure(Failure.failed("无法读取 Claude 的回复。"))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
