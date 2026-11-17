import Foundation

@main
enum LectureSummaryProbe {
    static func main() {
        let lines = [
            CaptionLine(english: "Today we discuss relational databases and primary keys.",
                        chinese: "今天我们讨论关系数据库和主键。"),
            CaptionLine(english: "A foreign key references a primary key in another table.",
                        chinese: "外键引用另一张表中的主键。"),
            CaptionLine(english: "Foreign keys preserve relationships between tables.",
                        chinese: "外键用于维护表之间的关系。"),
            CaptionLine(english: "Indexes can improve query performance.",
                        chinese: "索引可以提升查询性能。"),
            CaptionLine(english: "Foreign keys help keep database data consistent.",
                        chinese: "外键有助于保持数据库数据一致。")
        ]
        guard let summary = LectureSummary.make(from: lines),
              summary.contains("整体内容"), summary.contains("重点"),
              summary.contains("外键"), summary.contains("1. "),
              LectureSummary.make(from: []) == nil else {
            fatalError("Lecture summary was missing its core sections")
        }
        print("Summary has an overview and translated key points")
    }
}
