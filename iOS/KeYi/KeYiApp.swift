import SwiftUI

@main
struct KeYiApp: App {
    @StateObject private var session = LectureSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}

/// 字幕外观设置（保存在本机，重启后保留）。
enum CaptionAppearance {
    static let sizeKey = "CaptionSize"
    static let designKey = "CaptionDesign"
    static let colorKey = "CaptionColor"
    static let modeKey = "CaptionMode"

    static let designs: [(id: String, title: String, design: Font.Design)] = [
        ("default", "系统无衬线", .default), ("serif", "衬线", .serif),
        ("rounded", "圆体", .rounded), ("monospaced", "等宽", .monospaced)
    ]
    static let colors: [(id: String, title: String)] = [
        ("system", "跟随系统"), ("amber", "暖黄"), ("mint", "薄荷绿"), ("sky", "天蓝"), ("rose", "樱粉")
    ]
    static let modes: [(id: String, title: String)] = [("both", "英中对照"), ("english", "仅英文"), ("chinese", "仅中文")]

    static func design(_ id: String) -> Font.Design {
        designs.first { $0.id == id }?.design ?? .default
    }

    /// 返回（中文颜色, 英文颜色）。预设色在浅色与深色模式下各有可读的版本。
    static func colors(_ id: String, dark: Bool) -> (Color, Color) {
        let main: Color
        switch id {
        case "amber": main = dark ? Color(red: 1.0, green: 0.83, blue: 0.42) : Color(red: 0.60, green: 0.36, blue: 0.0)
        case "mint": main = dark ? Color(red: 0.50, green: 0.89, blue: 0.71) : Color(red: 0.07, green: 0.48, blue: 0.31)
        case "sky": main = dark ? Color(red: 0.55, green: 0.78, blue: 1.0) : Color(red: 0.12, green: 0.37, blue: 0.72)
        case "rose": main = dark ? Color(red: 1.0, green: 0.65, blue: 0.79) : Color(red: 0.70, green: 0.23, blue: 0.42)
        default: return (.primary, .secondary)
        }
        return (main, main.opacity(0.75))
    }
}
