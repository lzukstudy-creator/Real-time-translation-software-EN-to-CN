import SwiftUI

/// 四套主题 + 跟随系统（浅色用晨雾，深色用墨夜）。
enum ThemeID: String, CaseIterable, Identifiable {
    case auto, mist, ink, paper, graphite
    var id: String { rawValue }
    static let storageKey = "KeYiTheme"
}

struct KeYiTheme {
    enum ButtonKind { case candy, glow, seal, metal }
    enum Texture { case none, ruled, brushed }

    let id: ThemeID
    let title: String
    let subtitle: String
    let scheme: ColorScheme
    let backgroundTop: Color
    let backgroundBottom: Color
    let texture: Texture
    let surface: Color
    let surfaceStroke: Color
    let chinese: Color
    let english: Color
    let secondary: Color
    let accent: Color
    let onIdle: Color
    let idleStops: [Color]
    let activeStops: [Color]
    let markFill: Color
    let markStroke: Color
    let chineseDesign: Font.Design
    let englishDesign: Font.Design
    let englishItalic: Bool
    let buttonKind: ButtonKind
    let corner: CGFloat

    static func resolve(_ id: ThemeID, system: ColorScheme) -> KeYiTheme {
        switch id {
        case .auto: return system == .dark ? .ink : .mist
        case .mist: return .mist
        case .ink: return .ink
        case .paper: return .paper
        case .graphite: return .graphite
        }
    }

    static func title(of id: ThemeID) -> String {
        id == .auto ? "跟随系统" : resolve(id, system: .light).title
    }

    static let mist = KeYiTheme(
        id: .mist, title: "晨雾", subtitle: "清透玻璃，白天教室", scheme: .light,
        backgroundTop: .hex(0xF6F8FC), backgroundBottom: .hex(0xEAEFF7), texture: .none,
        surface: .white.opacity(0.72), surfaceStroke: .white.opacity(0.95),
        chinese: .hex(0x0B1324), english: .hex(0x4A5468), secondary: .hex(0x5B6478),
        accent: .hex(0x2F6FE4), onIdle: .white,
        idleStops: [.hex(0x6FA3FF), .hex(0x2F6FE4), .hex(0x1F55C0)],
        activeStops: [.hex(0xFF7A6E), .hex(0xE5372B), .hex(0xC1281E)],
        markFill: .hex(0x2F6FE4).opacity(0.08), markStroke: .hex(0x2F6FE4).opacity(0.18),
        chineseDesign: .default, englishDesign: .default, englishItalic: false, buttonKind: .candy, corner: 18)

    static let ink = KeYiTheme(
        id: .ink, title: "墨夜", subtitle: "深色琥珀，暗教室不刺眼", scheme: .dark,
        backgroundTop: .hex(0x161B26), backgroundBottom: .hex(0x07090D), texture: .none,
        surface: .hex(0x171C26).opacity(0.9), surfaceStroke: .white.opacity(0.08),
        chinese: .hex(0xFFF8EC), english: .hex(0xA9B1C1), secondary: .hex(0x9AA3B5),
        accent: .hex(0xF2B35B), onIdle: .hex(0x2A1C08),
        idleStops: [.hex(0xFFD08A), .hex(0xF2B35B), .hex(0xC78A33)],
        activeStops: [.hex(0xFF8A70), .hex(0xF0483A), .hex(0xB9261C)],
        markFill: .hex(0xF2B35B).opacity(0.09), markStroke: .hex(0xF2B35B).opacity(0.28),
        chineseDesign: .default, englishDesign: .default, englishItalic: false, buttonKind: .glow, corner: 18)

    static let paper = KeYiTheme(
        id: .paper, title: "纸笺", subtitle: "宣纸朱印，像在记笔记", scheme: .light,
        backgroundTop: .hex(0xF4EDE0), backgroundBottom: .hex(0xF1E8D8), texture: .ruled,
        surface: .hex(0xFBF7EF), surfaceStroke: .hex(0xD8CBB4),
        chinese: .hex(0x1E1810), english: .hex(0x5A4E3E), secondary: .hex(0x6F6250),
        accent: .hex(0xB8432F), onIdle: .hex(0xFBF3E6),
        idleStops: [.hex(0x2B2419), .hex(0x2B2419), .hex(0x120E08)],
        activeStops: [.hex(0xB8432F), .hex(0xB8432F), .hex(0x8E3020)],
        markFill: .hex(0xE2B24A).opacity(0.22), markStroke: .hex(0xC9A24A).opacity(0.35),
        chineseDesign: .serif, englishDesign: .serif, englishItalic: true, buttonKind: .seal, corner: 12)

    static let graphite = KeYiTheme(
        id: .graphite, title: "石墨", subtitle: "金属录音机，专业感", scheme: .dark,
        backgroundTop: .hex(0x1C1E21), backgroundBottom: .hex(0x16181A), texture: .brushed,
        surface: .hex(0x0F1012), surfaceStroke: .black,
        chinese: .white, english: .hex(0xAEB5BE), secondary: .hex(0x9CA3AC),
        accent: .hex(0x5FD3A6), onIdle: .hex(0x24272B),
        idleStops: [.hex(0xFF8C7F), .hex(0xC6362A), .hex(0xC6362A)],
        activeStops: [.hex(0xFF8C7F), .hex(0xE2392B), .hex(0xE2392B)],
        markFill: .hex(0x5FD3A6).opacity(0.07), markStroke: .hex(0x5FD3A6).opacity(0.3),
        chineseDesign: .default, englishDesign: .monospaced, englishItalic: false, buttonKind: .metal, corner: 12)
}

extension EnvironmentValues {
    @Entry var keyiTheme: KeYiTheme = .mist
}

extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

// MARK: 背景

struct ThemeBackground: View {
    let theme: KeYiTheme

    var body: some View {
        ZStack {
            if theme.id == .ink {
                RadialGradient(colors: [theme.backgroundTop, .hex(0x0A0D13), theme.backgroundBottom],
                               center: .top, startRadius: 0, endRadius: 700)
            } else {
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            }
            switch theme.texture {
            case .ruled:
                // 信纸横线
                Canvas { context, size in
                    var y: CGFloat = 34
                    while y < size.height {
                        context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                     with: .color(Color.hex(0x78603C).opacity(0.05)))
                        y += 34
                    }
                }
            case .brushed:
                // 拉丝金属的细竖纹
                Canvas { context, size in
                    var x: CGFloat = 0
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                     with: .color(.white.opacity(0.014)))
                        x += 3
                    }
                }
            case .none:
                EmptyView()
            }
        }
        .ignoresSafeArea()
    }
}

/// 卡片、术语条等表面。
struct ThemeSurface: ViewModifier {
    let theme: KeYiTheme
    var radius: CGFloat?
    var inset = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? theme.corner, style: .continuous)
        content
            .background {
                switch theme.buttonKind {
                case .candy:
                    shape.fill(theme.surface)
                        .shadow(color: .hex(0x1C305C).opacity(0.07), radius: 10, y: 5)
                case .glow:
                    shape.fill(theme.surface)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                case .seal:
                    shape.fill(theme.surface)
                case .metal:
                    shape.fill(theme.surface.shadow(.inner(color: .black.opacity(0.7), radius: 3, y: 2)))
                }
            }
            .overlay {
                if theme.buttonKind == .seal && inset {
                    shape.strokeBorder(theme.surfaceStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    shape.strokeBorder(theme.surfaceStroke, lineWidth: 1)
                }
            }
    }
}

extension View {
    func themeSurface(_ theme: KeYiTheme, radius: CGFloat? = nil, inset: Bool = false) -> some View {
        modifier(ThemeSurface(theme: theme, radius: radius, inset: inset))
    }
}

// MARK: 按钮

/// 主按钮（开始 / 结束收声）：每套主题一种质感，按下时有压下去的手感。
struct RecordButtonStyle: ButtonStyle {
    let theme: KeYiTheme
    let active: Bool
    var size: CGFloat = 78

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let stops = active ? theme.activeStops : theme.idleStops
        return ZStack {
            switch theme.buttonKind {
            case .candy, .glow:
                Circle()
                    .fill(RadialGradient(colors: stops, center: UnitPoint(x: 0.5, y: pressed ? 0.4 : 0.28),
                                         startRadius: 0, endRadius: size * 0.62)
                        .shadow(.inner(color: .white.opacity(pressed ? 0 : (theme.buttonKind == .candy ? 0.5 : 0.35)), radius: 0, y: 2))
                        .shadow(.inner(color: .black.opacity(pressed ? 0.32 : 0.2), radius: pressed ? 6 : 4, y: pressed ? 3 : -4)))
                    .shadow(color: stops[1].opacity(pressed ? 0.2 : (theme.buttonKind == .glow ? 0.45 : 0.36)),
                            radius: pressed ? 4 : 12, y: theme.buttonKind == .glow ? 0 : (pressed ? 2 : 8))
                if active {
                    Circle().stroke(stops[1].opacity(0.12), lineWidth: 7).padding(-7)
                }
            case .seal:
                Circle()
                    .fill(stops[0].shadow(.inner(color: .black.opacity(pressed ? 0.45 : 0.18), radius: pressed ? 5 : 3, y: pressed ? 3 : -3)))
                    .overlay(Circle().strokeBorder(theme.onIdle.opacity(0.82), lineWidth: 2).padding(4))
                    .background(Circle().fill(stops[2]).offset(y: pressed ? 1 : 4))
                    .offset(y: pressed ? 3 : 0)
                    .shadow(color: stops[2].opacity(pressed ? 0.1 : 0.25), radius: pressed ? 2 : 10, y: pressed ? 2 : 10)
            case .metal:
                Circle()
                    .fill(AngularGradient(colors: [.hex(0x9AA0A8), .hex(0xE3E6EA), .hex(0x8E949C), .hex(0xD6DADF), .hex(0x9AA0A8)],
                                          center: .center, angle: .degrees(pressed ? 40 : 20))
                        .shadow(.inner(color: pressed ? .black.opacity(0.45) : .white.opacity(0.5), radius: pressed ? 5 : 0, y: pressed ? 3 : 1)))
                    .overlay(Circle().strokeBorder(Color.hex(0x0C0D0F), lineWidth: 1))
                    .padding(6)
                    .background(Circle().fill(Color.hex(0x16181B)))
                    .overlay(Circle().strokeBorder(active ? theme.accent : .hex(0x3A3F45), lineWidth: 2))
                    .shadow(color: active ? theme.accent.opacity(0.45) : .black.opacity(0.6), radius: active ? 12 : 6, y: active ? 0 : 6)
            }
            configuration.label
                .offset(y: theme.buttonKind == .seal && pressed ? 3 : 0)
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed && theme.buttonKind != .seal ? 0.94 : 1)
        .animation(.spring(duration: 0.18, bounce: 0.35), value: pressed)
        .sensoryFeedback(.impact(weight: .medium), trigger: pressed) { _, now in now }
    }
}

/// 主按钮里的图标：普通主题用 SF Symbols，纸笺用“听 / 止”印章字，石墨用红色指示灯。
struct RecordGlyph: View {
    let theme: KeYiTheme
    let active: Bool
    let busy: Bool

    var body: some View {
        if busy {
            ProgressView().tint(theme.buttonKind == .metal ? .hex(0x24272B) : (active ? .white : theme.onIdle))
        } else {
            switch theme.buttonKind {
            case .seal:
                Text(active ? "止" : "听")
                    .font(.system(size: 23, weight: .bold, design: .serif))
                    .foregroundStyle(theme.onIdle)
            case .metal:
                RoundedRectangle(cornerRadius: active ? 6 : 12, style: .continuous)
                    .fill(RadialGradient(colors: [.hex(0xFF8C7F), active ? .hex(0xE2392B) : .hex(0xC6362A)],
                                         center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 16))
                    .frame(width: active ? 26 : 22, height: active ? 26 : 22)
                    .shadow(color: active ? .hex(0xFF5B4D).opacity(0.7) : .clear, radius: 6)
            case .candy, .glow:
                if active {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.buttonKind == .glow ? Color.hex(0xFFF6EC) : .white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.onIdle)
                }
            }
        }
    }
}

/// 次按钮（标重点、暂停、顶栏按钮）。
struct TactileButtonStyle: ButtonStyle {
    let theme: KeYiTheme
    var size: CGFloat = 54
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background { background(pressed: pressed) }
            .offset(y: theme.buttonKind == .seal && pressed ? 2 : 0)
            .scaleEffect(pressed && theme.buttonKind != .seal ? 0.93 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(duration: 0.16, bounce: 0.3), value: pressed)
    }

    private var foreground: Color {
        switch theme.buttonKind {
        case .candy: return .hex(0x101828)
        case .glow: return .hex(0xE9E3D6)
        case .seal: return .hex(0x2B2419)
        case .metal: return .hex(0x24272B)
        }
    }

    @ViewBuilder private func background(pressed: Bool) -> some View {
        switch theme.buttonKind {
        case .candy:
            Circle()
                .fill(LinearGradient(colors: pressed ? [.hex(0xE6EBF3), .hex(0xF3F6FA)] : [.white, .hex(0xEEF2F8)],
                                     startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: pressed ? .black.opacity(0.1) : .white, radius: pressed ? 3 : 0, y: 1)))
                .overlay(Circle().strokeBorder(Color.hex(0x101828).opacity(0.06), lineWidth: 1))
                .shadow(color: .hex(0x1C305C).opacity(pressed ? 0.05 : 0.1), radius: pressed ? 2 : 5, y: pressed ? 1 : 4)
        case .glow:
            Circle()
                .fill(LinearGradient(colors: pressed ? [.hex(0x141821), .hex(0x1E2430)] : [.hex(0x262D3B), .hex(0x171C26)],
                                     startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: pressed ? .black.opacity(0.5) : .white.opacity(0.1), radius: pressed ? 3 : 0, y: 1)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                .shadow(color: .black.opacity(pressed ? 0.2 : 0.45), radius: pressed ? 2 : 5, y: pressed ? 1 : 4)
        case .seal:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.hex(0xF4EDE0).shadow(.inner(color: pressed ? .black.opacity(0.12) : .white, radius: pressed ? 2 : 0, y: 1)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hex(0xD8CBB4), lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.hex(0xD4C6AE)).offset(y: pressed ? 0 : 2))
        case .metal:
            Circle()
                .fill(AngularGradient(colors: [.hex(0x8A9098), .hex(0xD9DDE2), .hex(0x80868E), .hex(0xCDD2D8), .hex(0x8A9098)],
                                      center: .center, angle: .degrees(pressed ? 40 : 20))
                    .shadow(.inner(color: pressed ? .black.opacity(0.4) : .white.opacity(0.5), radius: pressed ? 4 : 0, y: 1)))
                .overlay(Circle().strokeBorder(Color.hex(0x0C0D0F), lineWidth: 1))
                .shadow(color: .black.opacity(pressed ? 0.3 : 0.55), radius: pressed ? 2 : 4, y: pressed ? 1 : 3)
        }
    }
}

/// 控制条底板。晨雾用系统 Liquid Glass，其他主题各有材质。
struct ControlPlate: ViewModifier {
    let theme: KeYiTheme

    func body(content: Content) -> some View {
        switch theme.buttonKind {
        case .candy:
            content.glassEffect(.regular, in: .capsule)
        case .glow:
            content
                .background(Capsule().fill(LinearGradient(colors: [.hex(0x1E2430).opacity(0.94), .hex(0x11151D).opacity(0.94)],
                                                         startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: .white.opacity(0.08), radius: 0, y: 1))))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 20, y: 12)
        case .seal:
            content
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.hex(0xFBF7EF)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.hex(0xD8CBB4), lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.hex(0xDCCFB8)).offset(y: 3))
                .shadow(color: .hex(0x5C4624).opacity(0.12), radius: 14, y: 12)
        case .metal:
            content
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [.hex(0x4A4F56), .hex(0x2C2F34)], startPoint: .top, endPoint: .bottom)
                        .shadow(.inner(color: .white.opacity(0.18), radius: 0, y: 1)))
                    .overlay(Canvas { context, size in
                        var x: CGFloat = 0
                        while x < size.width {
                            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.035)))
                            x += 2
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.hex(0x0C0D0F), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 15, y: 12)
        }
    }
}

extension View {
    func controlPlate(_ theme: KeYiTheme) -> some View { modifier(ControlPlate(theme: theme)) }
}
