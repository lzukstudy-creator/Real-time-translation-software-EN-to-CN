import Foundation

@main
enum CaptionTimelineProbe {
    static func main() {
        var timeline = CaptionTimeline()
        timeline.updateEnglish("Hello world. This is the next sentence")
        precondition(timeline.lines.count == 2)
        precondition(timeline.applyTranslation(segment: 0, english: "Hello world.", chinese: "你好，世界。"))
        timeline.updateEnglish("Hello world. This is the next sentence.")
        precondition(timeline.lines[0].chinese == "你好，世界。")
        precondition(timeline.lines[1].chinese == nil)
        precondition(!timeline.applyTranslation(segment: 1,
                                                 english: "This is the next sentence",
                                                 chinese: "过期译文"))
        precondition(timeline.applyTranslation(segment: 1,
                                                english: "This is the next sentence.",
                                                chinese: "这是下一句话。"))
        timeline.updateEnglish("Hello world. This is the next sentence. More words")
        precondition(timeline.lines[1].chinese == "这是下一句话。")
        timeline.updateEnglish("Hello world. This is the next sentence with changes.")
        precondition(timeline.lines[1].chinese == "这是下一句话。")
        precondition(!timeline.applyTranslation(segment: 1,
                                                english: "This is the next sentence.",
                                                chinese: "过期译文"))
        precondition(timeline.applyTranslation(segment: 1,
                                                english: "This is the next sentence with changes.",
                                                chinese: "这是修改后的下一句话。"))
        precondition(timeline.displayText.contains("你好，世界。"))
        precondition(timeline.displayText.contains("这是修改后的下一句话。"))
        precondition(!timeline.displayText.contains("翻译中"))
        precondition(!timeline.displayText.contains("英文  "))
        precondition(!timeline.displayText.contains("中文  "))
        print("Paired captions retain translations and reject stale results")
    }
}
