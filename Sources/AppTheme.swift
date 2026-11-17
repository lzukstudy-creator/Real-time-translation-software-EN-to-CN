import AppKit

enum AccentChoice: String, CaseIterable {
    case blue, teal, violet, coral, amber

    static let preferenceKey = "TingYiAccentChoice"

    static var saved: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .blue
    }

    var title: String {
        switch self {
        case .blue: return "海蓝"
        case .teal: return "青绿"
        case .violet: return "紫罗兰"
        case .coral: return "珊瑚"
        case .amber: return "琥珀"
        }
    }

    func color(dark: Bool) -> NSColor {
        switch (self, dark) {
        case (.blue, false): return NSColor(hex: 0x3078E8)
        case (.blue, true): return NSColor(hex: 0x77A9FF)
        case (.teal, false): return NSColor(hex: 0x158D86)
        case (.teal, true): return NSColor(hex: 0x60D3C9)
        case (.violet, false): return NSColor(hex: 0x8564DB)
        case (.violet, true): return NSColor(hex: 0xAF98FF)
        case (.coral, false): return NSColor(hex: 0xCB625C)
        case (.coral, true): return NSColor(hex: 0xFF9C91)
        case (.amber, false): return NSColor(hex: 0xB76A2D)
        case (.amber, true): return NSColor(hex: 0xECAA68)
        }
    }

    func swatch(dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color(dark: dark).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
        image.unlockFocus()
        return image
    }
}

struct AppPalette {
    let dark: Bool
    let background: NSColor
    let surface: NSColor
    let text: NSColor
    let secondary: NSColor
    let border: NSColor
    let accent: NSColor
    let accentSoft: NSColor

    init(appearance: NSAppearance, accent choice: AccentChoice) {
        dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        background = NSColor(hex: dark ? 0x111727 : 0xF6F8FC)
        surface = NSColor(hex: dark ? 0x1C2639 : 0xFFFFFF)
        text = NSColor(hex: dark ? 0xF2F5FC : 0x182232)
        secondary = NSColor(hex: dark ? 0xAAB7CB : 0x697789)
        border = NSColor(hex: dark ? 0x344158 : 0xE3E8F0)
        accent = choice.color(dark: dark)
        accentSoft = accent.withAlphaComponent(dark ? 0.22 : 0.12)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

final class ThemeRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

final class AudioLevelView: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    var accentColor: NSColor = .systemBlue { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let heights: [CGFloat] = [9, 17, 25, 14, 22, 12, 19, 8]
        let active = Int((max(0, min(1, level)) * Double(heights.count)).rounded(.up))
        for (index, height) in heights.enumerated() {
            let bar = NSRect(x: CGFloat(index) * 9 + 3, y: (bounds.height - height) / 2,
                             width: 4, height: height)
            accentColor.withAlphaComponent(index < active ? 1 : 0.28).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        }
    }
}
