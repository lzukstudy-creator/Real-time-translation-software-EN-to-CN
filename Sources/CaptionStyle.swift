import AppKit

/// 字幕字体：英文使用对应风格的拉丁字体，中文通过级联字体使用同风格的中文字体。
enum CaptionFontChoice: String, CaseIterable {
    case system, serif, rounded, kai, mono

    static let preferenceKey = "TingYiCaptionFont"

    static var saved: CaptionFontChoice {
        CaptionFontChoice(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
    }

    var title: String {
        switch self {
        case .system: return "系统无衬线（苹方）"
        case .serif: return "衬线（宋体）"
        case .rounded: return "圆体"
        case .kai: return "楷体"
        case .mono: return "等宽"
        }
    }

    var chineseFamily: String {
        switch self {
        case .system, .mono: return "PingFang SC"
        case .serif: return "Songti SC"
        case .rounded: return "Yuanti SC"
        case .kai: return "Kaiti SC"
        }
    }

    func font(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base: NSFont
        switch self {
        case .system:
            base = .systemFont(ofSize: size, weight: weight)
        case .mono:
            base = .monospacedSystemFont(ofSize: size - 1, weight: weight)
        case .serif, .rounded:
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            let design: NSFontDescriptor.SystemDesign = self == .serif ? .serif : .rounded
            if let descriptor = system.fontDescriptor.withDesign(design),
               let font = NSFont(descriptor: descriptor, size: size) {
                base = font
            } else if self == .serif {
                base = NSFont(name: weight >= .medium ? "Georgia-Bold" : "Georgia", size: size) ?? system
            } else {
                base = system
            }
        case .kai:
            base = NSFont(name: weight >= .semibold ? "Baskerville-SemiBold" : "Baskerville", size: size + 1)
                ?? .systemFont(ofSize: size, weight: weight)
        }
        let chinese = NSFontDescriptor(fontAttributes: [
            .family: chineseFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        let cascaded = base.fontDescriptor.addingAttributes([.cascadeList: [chinese]])
        return NSFont(descriptor: cascaded, size: base.pointSize) ?? base
    }
}

/// 字幕颜色：“跟随主题”保持原有配色；预设颜色在浅色和深色外观下各有可读的版本。
enum CaptionColorChoice: String, CaseIterable {
    case theme, contrast, amber, mint, sky, rose, custom

    static let preferenceKey = "TingYiCaptionColor"
    static let customKey = "TingYiCaptionCustomColor"

    static var saved: CaptionColorChoice {
        CaptionColorChoice(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .theme
    }

    static var savedCustomColor: NSColor {
        let value = UserDefaults.standard.integer(forKey: customKey)
        return UserDefaults.standard.object(forKey: customKey) == nil
            ? NSColor(hex: 0x3078E8) : NSColor(hex: UInt32(truncatingIfNeeded: value))
    }

    static func saveCustom(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let hex = (Int((rgb.redComponent * 255).rounded()) << 16)
            | (Int((rgb.greenComponent * 255).rounded()) << 8)
            | Int((rgb.blueComponent * 255).rounded())
        UserDefaults.standard.set(hex, forKey: customKey)
    }

    var title: String {
        switch self {
        case .theme: return "跟随主题"
        case .contrast: return "高对比黑白"
        case .amber: return "暖黄"
        case .mint: return "薄荷绿"
        case .sky: return "天蓝"
        case .rose: return "樱粉"
        case .custom: return "自定义颜色…"
        }
    }

    /// 返回（中文颜色，英文颜色）。英文比中文略淡，保持原来的主次层次。
    func colors(palette: AppPalette) -> (chinese: NSColor, english: NSColor) {
        let dark = palette.dark
        let main: NSColor
        switch self {
        case .theme: return (palette.text, palette.secondary)
        case .contrast: main = dark ? .white : .black
        case .amber: main = NSColor(hex: dark ? 0xFFD36B : 0x9A5B00)
        case .mint: main = NSColor(hex: dark ? 0x7FE3B5 : 0x137A50)
        case .sky: main = NSColor(hex: dark ? 0x8CC8FF : 0x1F5FB8)
        case .rose: main = NSColor(hex: dark ? 0xFFA6C9 : 0xB23A6B)
        case .custom: main = Self.savedCustomColor
        }
        return (main, main.withAlphaComponent(0.78))
    }

    func swatch(palette: AppPalette) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        colors(palette: palette).chinese.setFill()
        let dot = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14))
        dot.fill()
        palette.border.setStroke()
        dot.stroke()
        image.unlockFocus()
        return image
    }
}

struct CaptionStyle {
    var font: CaptionFontChoice
    var color: CaptionColorChoice

    static var saved: CaptionStyle { CaptionStyle(font: .saved, color: .saved) }
}
