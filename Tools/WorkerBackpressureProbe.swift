import AVFoundation
import Foundation

@main
enum WorkerBackpressureProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { exit(2) }
        let audio = URL(fileURLWithPath: CommandLine.arguments[2])
        let file = try AVAudioFile(forReading: audio)
        let glossary = try GlossaryStore(resource: URL(fileURLWithPath: CommandLine.arguments[3]),
                                         customURL: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("tingyi-backpressure-terms.json"))
        let worker = try RecognitionWorker(model: URL(fileURLWithPath: CommandLine.arguments[1]),
                                           inputFormat: file.processingFormat,
                                           hotwords: glossary.hotwords)
        let recovery = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var droppedAudio = false
        var fatalErrorReported = false
        var transcript = ""
        worker.onWarning = { message in
            lock.lock()
            if message.contains("跳过") { droppedAudio = true }
            lock.unlock()
            if message.contains("已恢复") { recovery.signal() }
        }
        worker.onError = { _ in
            lock.lock(); fatalErrorReported = true; lock.unlock()
        }
        for _ in 0..<4 {
            file.framePosition = 0
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: 1600) else { break }
                try file.read(into: buffer, frameCount: 1600)
                worker.submit(buffer)
            }
        }
        guard recovery.wait(timeout: .now() + 45) == .success else {
            fatalError("Recognition backlog did not recover")
        }
        file.framePosition = 0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: 1600) else { break }
            try file.read(into: buffer, frameCount: 1600)
            worker.submit(buffer)
            Thread.sleep(forTimeInterval: 0.1)
        }
        worker.finish { text in transcript = text; finished.signal() }
        guard finished.wait(timeout: .now() + 45) == .success else {
            fatalError("Recognition did not finish")
        }
        lock.lock()
        let passed = droppedAudio && !fatalErrorReported && !transcript.isEmpty
        lock.unlock()
        guard passed else { fatalError("Backpressure did not stay nonfatal") }
        print("Backpressure recovered; recognition continued")
    }
}
