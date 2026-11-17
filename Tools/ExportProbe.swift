import Foundation
@main enum ExportProbe { static func main() {
  var t = CaptionTimeline()
  t.updateEnglish("Recursion calls itself. A base case stops it. Remember the call stack.")
  _ = t.applyTranslation(segment: 0, english: "Recursion calls itself.", chinese: "递归调用自身。")
  precondition(t.toggleLatestMark(seconds: 12))
  precondition(t.isMarked(2) && t.isMarked(1), "short latest line should also mark previous")
  precondition(t.displayText.contains("★ Remember the call stack."))
  precondition(!t.toggleLatestMark(seconds: 13) && t.marks.isEmpty, "second press unmarks")
  _ = t.toggleLatestMark(seconds: 14)
  let lines = t.lines.enumerated().map { LectureExport.Line(start: Double($0.offset) * 3.5, english: $0.element.english, chinese: $0.element.chinese, marked: t.isMarked($0.offset)) }
  let srt = LectureExport.srt(lines, end: 20)
  precondition(srt.hasPrefix("1\n00:00:00,000 --> 00:00:03,500\nRecursion calls itself.\n递归调用自身。\n"), srt)
  precondition(srt.contains("★ Remember the call stack."))
  let md = LectureExport.markdown(lines, date: Date(), terms: [("call stack", "调用栈")], summary: nil)
  precondition(md.contains("## ★ 重点") && md.contains("| call stack | 调用栈 |"))
  print(md); print("Marks and exports OK")
}}
