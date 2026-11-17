import Foundation
import SwiftUI
import Translation

struct TranslationInput: Sendable {
    let id: Int
    let session: Int
    let segment: Int
    let seconds: Double
    let english: String
    /// 实际送去翻译的文本（清理过口语填充词）。
    var source: String { TranslationText.clean(english) }
}

final class ChineseTranslation: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var status = "中文翻译待启动"

    var onResult: ((TranslationInput, String) -> Void)?
    var onStatus: (() -> Void)?

    private let inputs: AsyncStream<TranslationInput>
    private let continuation: AsyncStream<TranslationInput>.Continuation
    private var preparing = false
    private(set) var ready = false

    init() {
        var saved: AsyncStream<TranslationInput>.Continuation?
        inputs = AsyncStream(bufferingPolicy: .unbounded) { saved = $0 }
        continuation = saved!
    }

    func prepare() {
        guard !ready, !preparing else { return }
        preparing = true
        setStatus("正在准备本机中文翻译…")
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans")
            )
        } else {
            configuration?.invalidate()
        }
    }

    func submit(_ input: TranslationInput) { continuation.yield(input) }

    func run(using translator: TranslationSession) async {
        do {
            try await translator.prepareTranslation()
            await MainActor.run {
                self.ready = true
                self.preparing = false
                self.setStatus("中文翻译已就绪")
            }
            for await input in inputs {
                if Task.isCancelled { return }
                do {
                    let response = try await translator.translate(input.source)
                    await MainActor.run { self.onResult?(input, response.targetText) }
                } catch {
                    await MainActor.run { self.setStatus("中文翻译出错：\(error.localizedDescription)") }
                }
            }
        } catch {
            await MainActor.run {
                self.ready = false
                self.preparing = false
                self.setStatus("中文翻译未就绪：\(error.localizedDescription)")
            }
        }
    }

    private func setStatus(_ value: String) {
        status = value
        onStatus?()
    }
}

struct ChineseTranslationHost: View {
    @ObservedObject var translator: ChineseTranslation

    var body: some View {
        Text(translator.status)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .translationTask(translator.configuration) { session in
                await translator.run(using: session)
            }
    }
}
