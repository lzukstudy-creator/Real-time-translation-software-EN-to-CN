import AVFoundation
import Foundation

@main
enum WorkerProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else { exit(2) }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
        let hotwords: [String]
        if CommandLine.arguments.count == 4 {
            let glossary = try GlossaryStore(
                resource: URL(fileURLWithPath: CommandLine.arguments[3]),
                customURL: FileManager.default.temporaryDirectory.appendingPathComponent("tingyi-probe-terms.json")
            )
            hotwords = glossary.hotwords
        } else {
            hotwords = []
        }
        let worker = try RecognitionWorker(model: URL(fileURLWithPath: CommandLine.arguments[1]),
                                           inputFormat: file.processingFormat, hotwords: hotwords)
        if !hotwords.isEmpty && !worker.enhanced { fatalError("Hotword enhancement did not activate") }
        worker.onError = { fputs("\($0)\n", stderr) }
        let frames: AVAudioFrameCount = 1600
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            worker.submit(buffer)
            Thread.sleep(forTimeInterval: 0.1)
        }
        let done = DispatchSemaphore(value: 0)
        var finalText = ""
        worker.finish { text in finalText = text; done.signal() }
        guard done.wait(timeout: .now() + 20) == .success else { exit(1) }
        print(finalText)
        if finalText.isEmpty { exit(1) }
    }
}
