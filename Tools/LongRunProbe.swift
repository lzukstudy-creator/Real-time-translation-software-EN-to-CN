import AVFoundation
import Foundation

@main
enum LongRunProbe {
    static func main() throws {
        guard CommandLine.arguments.count >= 5,
              let repetitions = Int(CommandLine.arguments[4]), repetitions > 0 else { exit(2) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingyi-long-run-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let glossary = try GlossaryStore(resource: URL(fileURLWithPath: CommandLine.arguments[3]),
                                         customURL: root.appendingPathComponent("terms.json"))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
        let archive = try BilingualArchive(stagingDirectory: root.appendingPathComponent("staging"),
                                           destinationDirectory: root.appendingPathComponent("finished"))
        let plain = CommandLine.arguments.count > 5 && CommandLine.arguments[5] == "plain"
        let worker = try RecognitionWorker(model: URL(fileURLWithPath: CommandLine.arguments[1]),
                                           inputFormat: file.processingFormat,
                                           hotwords: plain ? [] : glossary.hotwords)
        guard plain || worker.enhanced else { fatalError("Term enhancement was not activated") }
        let start = ProcessInfo.processInfo.systemUptime
        worker.onText = { archive.setEnglish($0) }
        worker.onError = {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            fputs(String(format: "Recognition error after %.1f sec: %@\n", elapsed, $0), stderr)
            exit(1)
        }
        let frames: AVAudioFrameCount = 1600
        for repetition in 0..<repetitions {
            file.framePosition = 0
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: frames) else { fatalError("No audio buffer") }
                try file.read(into: buffer, frameCount: frames)
                worker.submit(buffer)
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / file.processingFormat.sampleRate)
            }
            if (repetition + 1) % 5 == 0 {
                fputs("Completed \(repetition + 1) samples\n", stderr)
            }
        }
        let finishedRecognition = DispatchSemaphore(value: 0)
        var finalText = ""
        worker.finish { text in finalText = text; finishedRecognition.signal() }
        guard finishedRecognition.wait(timeout: .now() + 20) == .success else {
            fatalError("Recognizer did not finish")
        }
        archive.setEnglish(finalText)
        let finishedArchive = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        archive.finish(reason: "连续样本测试") { value in result = value; finishedArchive.signal() }
        guard finishedArchive.wait(timeout: .now() + 10) == .success,
              let output = try result?.get() else { fatalError("Archive did not finish") }
        let saved = try String(contentsOf: output, encoding: .utf8)
        guard finalText.contains("foreign key"), saved.contains(finalText) else {
            fatalError("Transcript was missing from the saved file")
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "%.1f seconds of continuous audio, %d words, saved transcript OK",
                     elapsed, finalText.split(separator: " ").count))
    }
}
