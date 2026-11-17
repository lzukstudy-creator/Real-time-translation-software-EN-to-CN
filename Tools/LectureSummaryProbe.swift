import Foundation

/// 本机课后总结自检：必须有核心内容、主线、重点；学生标记的句子必须进入重点；去掉口头禅。
@main
enum LectureSummaryProbe {
    static func main() {
        let pairs: [(String, String, Bool)] = [
            ("Today we discuss relational databases and primary keys in some detail.", "今天我们详细讨论关系数据库和主键。", false),
            ("A foreign key references the primary key in another table.", "外键引用另一张表中的主键。", true),
            ("Um so yeah okay so like we we go on now.", "嗯，所以，好吧，我们继续。", false),
            ("Foreign keys preserve relationships between the tables we design.", "外键用于维护我们设计的表之间的关系。", false),
            ("Remember this is important for the exam next week.", "记住，这对下周的考试很重要。", false),
            ("Indexes can improve query performance but slow down inserts.", "索引可以提升查询性能，但会减慢插入。", false)
        ]
        let lines = pairs.enumerated().map { LectureSummary.Line(start: Double($0.offset) * 30, english: $0.element.0,
                                                                  chinese: $0.element.1, marked: $0.element.2) }
        guard let summary = LectureSummary.make(lines: lines, terms: [("foreign key", "外键")]) else {
            fatalError("no summary")
        }
        for section in ["核心内容", "本节主线", "重点", "本节术语", "★ 外键引用另一张表中的主键。", "考试"] {
            precondition(summary.contains(section), "missing \(section):\n\(summary)")
        }
        precondition(!summary.contains("嗯"), "filler kept")
        precondition(LectureSummary.make(lines: []) == nil)
        print(summary)
        print("Local lecture summary OK")
    }
}
