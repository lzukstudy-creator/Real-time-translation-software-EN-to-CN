import ActivityKit
import Foundation

/// 锁屏和灵动岛上的“实时字幕”：App 和小组件扩展共用这份数据结构。
struct LiveCaptionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 最新一句已翻译的中文。
        var chinese: String
        /// 最新一句英文（可能还没翻译完）。
        var english: String
        /// 计时起点：现在减去已收声时长（暂停不计）。
        var startedAt: Date
        /// 暂停时冻结的时长；收声中为 nil。
        var pausedElapsed: Double?
        var marks: Int
    }

    var title: String
}

extension LiveCaptionAttributes.ContentState {
    var isPaused: Bool { pausedElapsed != nil }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
