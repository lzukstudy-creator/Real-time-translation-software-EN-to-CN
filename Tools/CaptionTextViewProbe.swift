import AppKit

@main
enum CaptionTextViewProbe {
    static func main() {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let view = CaptionTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        scroll.documentView = view
        view.observeScrolling()
        let captions = [
            "Hello world.\n你好，世界。",
            "Hello world.\n你好，世界呀。",
            "Hello world.\n你好，世界呀。\n\nNew sentence 👋",
            "Hello world.\n你好，世界呀。\n\nNew sentence 👋\n新的句子。",
            "Hello world.\n你好，世界呀。\n\nNew sentence 👋\n新句子。"
        ]
        for content in captions {
            view.updateCaptions(content, fontSize: 20)
            precondition(view.string == content, "Incremental edit corrupted captions")
        }
        print("Incremental Chinese and English caption edits OK")

        // 字幕样式：每种字体和颜色都应用到中英文行，且不改变字幕内容。
        view.animatesCaptions = true
        let palette = AppPalette(appearance: NSAppearance(named: .aqua)!, accent: .blue)
        for fontChoice in CaptionFontChoice.allCases {
            for colorChoice in CaptionColorChoice.allCases {
                view.applyStyle(CaptionStyle(font: fontChoice, color: colorChoice), palette: palette)
                let storage = view.textStorage!
                let colors = colorChoice.colors(palette: palette)
                let english = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                let chineseIndex = (storage.string as NSString).range(of: "你好").location
                let chinese = storage.attribute(.foregroundColor, at: chineseIndex, effectiveRange: nil) as? NSColor
                precondition(english == colors.english && chinese == colors.chinese, "Caption colors not applied")
                let font = storage.attribute(.font, at: chineseIndex, effectiveRange: nil) as? NSFont
                let englishFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                precondition(englishFont?.fontName == fontChoice.font(ofSize: 19, weight: .regular).fontName,
                             "English caption font not applied: \(fontChoice)")
                precondition(font?.familyName == fontChoice.chineseFamily || [.system, .mono].contains(fontChoice),
                             "Chinese caption font not applied: \(fontChoice) \(String(describing: font?.familyName))")
            }
            view.updateCaptions(captions.last! + "\n\nAnother line\n另一行。", fontSize: 20)
            precondition(view.string.hasSuffix("另一行。"), "Animated update corrupted captions")
            view.updateCaptions(captions.last!, fontSize: 20)
        }
        print("Caption font and colour styles OK")
    }
}
