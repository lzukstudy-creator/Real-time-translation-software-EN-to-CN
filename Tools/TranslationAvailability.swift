import Foundation
import Translation

@main
enum TranslationAvailabilityProbe {
    static func main() async {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed: print("installed")
        case .supported: print("supported-not-installed")
        case .unsupported: print("unsupported")
        @unknown default: print("unknown")
        }
    }
}
