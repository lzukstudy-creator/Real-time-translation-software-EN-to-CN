import SwiftUI

@main
struct KeYiApp: App {
    @StateObject private var session = LectureSession.shared

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environmentObject(session)
        }
    }
}

/// 读取主题设置，把主题和对应的深浅色交给整个界面（包括弹出的设置页）。
struct ThemedRoot: View {
    @AppStorage(ThemeID.storageKey) private var themeID = ThemeID.auto.rawValue
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let id = ThemeID(rawValue: themeID) ?? .auto
        let theme = KeYiTheme.resolve(id, system: systemScheme)
        ContentView()
            .environment(\.keyiTheme, theme)
            .tint(theme.accent)
            .preferredColorScheme(id == .auto ? nil : theme.scheme)
    }
}

/// 字幕外观设置（保存在本机，重启后保留）。
enum CaptionAppearance {
    static let sizeKey = "CaptionSize"
    static let designKey = "CaptionDesign"
    static let colorKey = "CaptionColor"
    static let modeKey = "CaptionMode"

    static let designs: [(id: String, title: String, design: Font.Design)] = [
        ("default", "跟随主题", .default), ("sans", "无衬线", .default), ("serif", "衬线", .serif),
        ("rounded", "圆体", .rounded), ("monospaced", "等宽", .monospaced)
    ]
    static let colors: [(id: String, title: String)] = [
        ("system", "跟随主题"), ("amber", "暖黄"), ("mint", "薄荷绿"), ("sky", "天蓝"), ("rose", "樱粉")
    ]
    static let modes: [(id: String, title: String)] = [("both", "英中对照"), ("english", "仅英文"), ("chinese", "仅中文")]

    /// 返回（中文字体, 英文字体, 英文是否斜体）。
    static func fonts(_ id: String, theme: KeYiTheme) -> (Font.Design, Font.Design, Bool) {
        guard id != "default", let design = designs.first(where: { $0.id == id })?.design else {
            return (theme.chineseDesign, theme.englishDesign, theme.englishItalic)
        }
        return (design, design, false)
    }

    /// 返回（中文颜色, 英文颜色）。预设色在浅色与深色主题下各有可读的版本。
    static func colors(_ id: String, theme: KeYiTheme) -> (Color, Color) {
        let dark = theme.scheme == .dark
        let main: Color
        switch id {
        case "amber": main = dark ? Color(red: 1.0, green: 0.83, blue: 0.42) : Color(red: 0.60, green: 0.36, blue: 0.0)
        case "mint": main = dark ? Color(red: 0.50, green: 0.89, blue: 0.71) : Color(red: 0.07, green: 0.48, blue: 0.31)
        case "sky": main = dark ? Color(red: 0.55, green: 0.78, blue: 1.0) : Color(red: 0.12, green: 0.37, blue: 0.72)
        case "rose": main = dark ? Color(red: 1.0, green: 0.65, blue: 0.79) : Color(red: 0.70, green: 0.23, blue: 0.42)
        default: return (theme.chinese, theme.english)
        }
        return (main, main.opacity(0.75))
    }
}
