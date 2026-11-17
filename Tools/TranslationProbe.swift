import Foundation
import Translation

@main
enum TranslationProbe {
    static func main() async throws {
        let translator = TranslationSession(
            installedSource: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "zh-Hans")
        )
        let response = try await translator.translate(
            "Today we will discuss databases and the foreign key relationship between two tables."
        )
        print(response.targetText)
    }
}
