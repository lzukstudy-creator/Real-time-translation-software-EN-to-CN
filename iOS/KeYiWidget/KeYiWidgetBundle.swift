import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct KeYiWidgetBundle: WidgetBundle {
    var body: some Widget {
        LiveCaptionLiveActivity()
    }
}

/// 锁屏实时字幕 + 灵动岛。
struct LiveCaptionLiveActivity: Widget {
    private static let accent = Color(red: 0.23, green: 0.48, blue: 0.94)
    private static let rec = Color(red: 1.0, green: 0.42, blue: 0.37)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveCaptionAttributes.self) { context in
            LockScreenCaption(state: context.state)
                .activityBackgroundTint(Color(red: 0.11, green: 0.125, blue: 0.165).opacity(0.78))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("课译", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.accent)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerLabel(state: context.state)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.isPaused ? .secondary : Self.rec)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.chinese)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)
                        ActionButtons(state: context.state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                TimerLabel(state: context.state)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.state.isPaused ? .secondary : Self.rec)
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(Self.accent)
            }
            .keylineTint(Self.accent)
        }
    }
}

private struct TimerLabel: View {
    let state: LiveCaptionAttributes.ContentState

    var body: some View {
        if let paused = state.pausedElapsed {
            Text(LiveCaptionAttributes.ContentState.clock(paused))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ActionButtons: View {
    let state: LiveCaptionAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: MarkMomentIntent()) {
                Label(state.marks > 0 ? "重点 \(state.marks)" : "标为重点", systemImage: "star.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(Color(red: 1.0, green: 0.82, blue: 0.48))
            Button(intent: TogglePauseIntent()) {
                Label(state.isPaused ? "继续" : "暂停", systemImage: state.isPaused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.white)
        }
        .font(.system(size: 14, weight: .semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
}

private struct LockScreenCaption: View {
    let state: LiveCaptionAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color(red: 0.23, green: 0.48, blue: 0.94), in: RoundedRectangle(cornerRadius: 6))
                Text(state.isPaused ? "课译 · 已暂停" : "课译 · 收声中")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(state.isPaused ? Color.gray : Color(red: 1, green: 0.42, blue: 0.37)).frame(width: 6, height: 6)
                    TimerLabel(state: state).frame(maxWidth: 70, alignment: .trailing)
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(state.isPaused ? Color.gray : Color(red: 1, green: 0.42, blue: 0.37))
            }
            Text(state.chinese)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(2)
            if !state.english.isEmpty {
                Text(state.english)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            ActionButtons(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}
