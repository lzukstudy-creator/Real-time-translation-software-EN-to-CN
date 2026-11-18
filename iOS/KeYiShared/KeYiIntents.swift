import AppIntents
import Foundation

/// 课译的快捷操作。锁屏按钮、Siri、操作按钮、快捷指令都走这里；真正的动作在 App 里执行。
enum KeYiAction: String, Sendable { case start, mark, pause, stop }

@MainActor
enum KeYiIntentBridge {
    /// App 启动时设置；小组件扩展里为空（锁屏按钮的意图会在 App 进程里运行）。
    static var handler: ((KeYiAction) async -> Void)?

    static func run(_ action: KeYiAction) async {
        // App 被快捷指令冷启动时，等界面准备好再执行。
        for _ in 0..<30 where handler == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await handler?(action)
    }
}

struct StartLectureIntent: AppIntent {
    static let title: LocalizedStringResource = "开始收声"
    static let description = IntentDescription("打开课译并开始收声。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await KeYiIntentBridge.run(.start)
        return .result()
    }
}

struct MarkMomentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "标记重点"
    static let description = IntentDescription("把老师刚说的这句标为重点。")

    func perform() async throws -> some IntentResult {
        await KeYiIntentBridge.run(.mark)
        return .result()
    }
}

struct TogglePauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暂停或继续收声"
    static let description = IntentDescription("暂停收声；已暂停时继续。")

    func perform() async throws -> some IntentResult {
        await KeYiIntentBridge.run(.pause)
        return .result()
    }
}

struct StopLectureIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "结束收声"
    static let description = IntentDescription("结束这节课，保存字幕并生成总结。")

    func perform() async throws -> some IntentResult {
        await KeYiIntentBridge.run(.stop)
        return .result()
    }
}
