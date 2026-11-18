import ActivityKit
import AppIntents
import Foundation

/// 管理锁屏 / 灵动岛上的实时字幕。更新做了节流，避免频繁刷新耗电。
@MainActor
final class LiveCaptionActivity {
    private var activity: Activity<LiveCaptionAttributes>?
    private var lastPush = Date.distantPast
    private var pending: LiveCaptionAttributes.ContentState?
    private var scheduled = false
    private let interval: TimeInterval = 2

    init() {
        // 上次 App 被系统结束时可能留下旧的实时活动。
        for old in Activity<LiveCaptionAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(_ state: LiveCaptionAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end(state)
        activity = try? Activity.request(attributes: LiveCaptionAttributes(title: "课译"),
                                         content: .init(state: state, staleDate: nil))
        lastPush = Date()
    }

    func update(_ state: LiveCaptionAttributes.ContentState, immediate: Bool = false) {
        guard activity != nil else { return }
        pending = state
        let wait = interval - Date().timeIntervalSince(lastPush)
        if immediate || wait <= 0 { push(); return }
        guard !scheduled else { return }
        scheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.scheduled = false
            self?.push()
        }
    }

    func end(_ state: LiveCaptionAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        pending = nil
        Task { await activity.end(state.map { .init(state: $0, staleDate: nil) }, dismissalPolicy: .immediate) }
    }

    private func push() {
        guard let activity, let state = pending else { return }
        pending = nil
        lastPush = Date()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }
}

/// Siri、操作按钮、快捷指令里能直接用的课译动作。
struct KeYiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartLectureIntent(),
                    phrases: ["用\(.applicationName)开始收声", "\(.applicationName)开始收声", "Start \(.applicationName)"],
                    shortTitle: "开始收声", systemImageName: "mic.fill")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["用\(.applicationName)标记重点", "\(.applicationName)标重点"],
                    shortTitle: "标记重点", systemImageName: "star.fill")
        AppShortcut(intent: TogglePauseIntent(),
                    phrases: ["\(.applicationName)暂停收声"],
                    shortTitle: "暂停 / 继续", systemImageName: "pause.fill")
        AppShortcut(intent: StopLectureIntent(),
                    phrases: ["用\(.applicationName)结束收声", "\(.applicationName)下课"],
                    shortTitle: "结束收声", systemImageName: "stop.fill")
    }
}
