import AppKit
import Foundation

private let canvas = NSSize(width: 1620, height: 690)

private struct Palette {
    let name: String
    let note: String
    let background: NSColor
    let surface: NSColor
    let soft: NSColor
    let text: NSColor
    let secondary: NSColor
    let border: NSColor
    let accent: NSColor
    let buttonText: NSColor
}

private func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

private let themes = [
    Palette(name: "云白 · 海蓝", note: "轻盈清晰，适合日常听课", background: color(0xF6F8FC),
            surface: .white, soft: color(0xEAF2FF), text: color(0x182232),
            secondary: color(0x697789), border: color(0xE3E8F0), accent: color(0x3078E8),
            buttonText: .white),
    Palette(name: "夜幕 · 紫罗兰", note: "低亮度，适合长时间阅读", background: color(0x111727),
            surface: color(0x1C2639), soft: color(0x332A57), text: color(0xF2F5FC),
            secondary: color(0xAAB7CB), border: color(0x344158), accent: color(0x9A80FB),
            buttonText: color(0x111727)),
    Palette(name: "暖纸 · 琥珀", note: "柔和暖色，适合专注阅读", background: color(0xF7F3EB),
            surface: color(0xFFFDF8), soft: color(0xFAE8D6), text: color(0x332B22),
            secondary: color(0x84776A), border: color(0xE8DED0), accent: color(0xBB6B30),
            buttonText: .white)
]

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvas.height - y - height, width: width, height: height)
}

private func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                 radius: CGFloat, fill: NSColor, border: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect(x, y, width, height), xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let border {
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ fill: NSColor) {
    fill.setFill()
    rect(x, y, width, 1).fill()
}

private func label(_ content: String, _ x: CGFloat, _ y: CGFloat,
                   _ width: CGFloat, _ height: CGFloat, size: CGFloat,
                   weight: NSFont.Weight = .regular, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style
    ]
    (content as NSString).draw(in: rect(x, y, width, height), withAttributes: attributes)
}

private func drawTheme(_ theme: Palette, index: Int) {
    let x = CGFloat(36 + index * 530)
    label(theme.name, x + 2, 24, 480, 31, size: 24, weight: .semibold, color: color(0x232A33))
    label(theme.note, x + 2, 57, 480, 20, size: 13, color: color(0x67717D))
    box(x, 93, 500, 559, radius: 16, fill: theme.background, border: color(0xC8CED8))
    box(x + 1, 94, 498, 38, radius: 15, fill: theme.surface)
    line(x + 1, 131, 498, theme.border)
    for (offset, dot) in [color(0xFF6057), color(0xFFBD2E), color(0x28C840)].enumerated() {
        box(x + 16 + CGFloat(offset) * 17, 107, 10, 10, radius: 5, fill: dot)
    }
    label("课译", x + 224, 104, 70, 20, size: 12, weight: .medium, color: theme.secondary)
    box(x + 22, 156, 39, 39, radius: 11, fill: theme.soft)
    label("∞", x + 28, 154, 34, 42, size: 28, weight: .bold, color: theme.accent)
    label("课译", x + 72, 153, 220, 30, size: 22, weight: .bold, color: theme.text)
    label("实时听课 · 英中对照", x + 73, 183, 240, 19, size: 12, color: theme.secondary)
    box(x + 392, 163, 86, 30, radius: 8, fill: theme.soft)
    label("沉浸字幕", x + 401, 169, 75, 18, size: 12, weight: .medium, color: theme.accent)
    box(x + 22, 216, 456, 86, radius: 12, fill: theme.surface, border: theme.border)
    box(x + 39, 236, 8, 8, radius: 4, fill: color(0x34B888))
    label("正在收声并翻译", x + 56, 228, 210, 23, size: 14, weight: .semibold, color: theme.text)
    label("内建麦克风 · 字幕自动保存", x + 39, 255, 275, 20, size: 11, color: theme.secondary)
    for (j, height) in [7, 14, 23, 11, 18, 9, 16].enumerated() {
        box(x + 310 + CGFloat(j) * 8, 268 - CGFloat(height), 4, CGFloat(height), radius: 2, fill: theme.accent)
    }
    box(x + 380, 240, 86, 33, radius: 9, fill: theme.accent)
    label("停止收声", x + 391, 248, 77, 20, size: 12, weight: .semibold, color: theme.buttonText)
    box(x + 22, 317, 456, 271, radius: 12, fill: theme.surface, border: theme.border)
    label("实时字幕", x + 40, 335, 200, 20, size: 14, weight: .semibold, color: theme.text)
    label("英中逐段对应", x + 355, 338, 110, 18, size: 11, color: theme.secondary)
    line(x + 23, 369, 454, theme.border)
    label("Today we will explore how artificial intelligence changes learning.",
          x + 42, 383, 420, 37, size: 13, color: theme.secondary)
    label("今天我们将探讨人工智能如何改变学习方式。", x + 42, 421, 420, 31,
          size: 16, weight: .medium, color: theme.text)
    line(x + 41, 464, 418, theme.border)
    label("The key is to ask good questions and verify each answer.",
          x + 42, 478, 420, 36, size: 13, color: theme.secondary)
    box(x + 40, 522, 3, 26, radius: 1, fill: theme.accent)
    label("关键是提出好问题，并核实每一个答案。", x + 52, 523, 410, 31,
          size: 16, weight: .medium, color: theme.text)
    for (j, title) in ["回看", "悬浮字幕", "字幕文件", "导出字幕"].enumerated() {
        let widths: [CGFloat] = [53, 85, 78, 79]
        let positions: [CGFloat] = [22, 83, 176, 262]
        box(x + positions[j], 605, widths[j], 29, radius: 8, fill: theme.surface, border: theme.border)
        label(title, x + positions[j] + 10, 611, widths[j] - 12, 18,
              size: 11, color: theme.text)
    }
    label("A−   A+", x + 392, 610, 75, 22, size: 12, weight: .medium, color: theme.secondary)
}

@main
enum ThemePreview {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Usage", code: 1) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "Bitmap", code: 2)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas).fill()
        for (index, theme) in themes.enumerated() { drawTheme(theme, index: index) }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PNG", code: 3)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
