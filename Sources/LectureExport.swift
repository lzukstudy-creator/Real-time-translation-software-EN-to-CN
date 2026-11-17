import Foundation

/// 课后导出：SRT 字幕（配合课堂录像）和 Markdown 学习笔记（重点、术语、总结、全文）。
enum LectureExport {
    struct Line {
        let start: Double
        let english: String
        let chinese: String?
        let marked: Bool
    }

    static func srt(_ lines: [Line], end: Double) -> String {
        var output = ""
        for (index, line) in lines.enumerated() {
            let next = index + 1 < lines.count ? lines[index + 1].start : max(end, line.start + 4)
            let stop = max(line.start + 1, min(next, line.start + 12))
            output += "\(index + 1)\n\(timestamp(line.start)) --> \(timestamp(stop))\n"
            output += (line.marked ? "★ " : "") + line.english + "\n"
            if let chinese = line.chinese, !chinese.isEmpty { output += chinese + "\n" }
            output += "\n"
        }
        return output
    }

    static func markdown(_ lines: [Line], date: Date, terms: [(english: String, chinese: String)],
                         summary: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        var output = "# 课堂笔记 · \(formatter.string(from: date))\n\n"
        output += "> 由课译自动识别与翻译，可能有误。\n\n"
        let marked = lines.filter(\.marked)
        if !marked.isEmpty {
            output += "## ★ 重点\n\n"
            for line in marked {
                output += "- **[\(clock(line.start))]** \(line.english)"
                if let chinese = line.chinese, !chinese.isEmpty { output += "  \n  \(chinese)" }
                output += "\n"
            }
            output += "\n"
        }
        if !terms.isEmpty {
            output += "## 本节术语\n\n| 英文 | 中文 |\n|---|---|\n"
            for term in terms { output += "| \(escape(term.english)) | \(escape(term.chinese)) |\n" }
            output += "\n"
        }
        if let summary, !summary.isEmpty { output += "## 演讲总结\n\n\(summary)\n\n" }
        output += "## 英中对照全文\n\n"
        for line in lines {
            output += "**[\(clock(line.start))]**\(line.marked ? " ★" : "") \(line.english)\n"
            if let chinese = line.chinese, !chinese.isEmpty { output += "\n\(chinese)\n" }
            output += "\n"
        }
        return output
    }

    private static func timestamp(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60_000 % 60,
                      millis / 1000 % 60, millis % 1000)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
}
