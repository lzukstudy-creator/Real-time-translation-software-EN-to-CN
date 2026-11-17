import AVFoundation
import Foundation

@main
enum RecognitionProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: RecognitionProbe MODEL_DIRECTORY AUDIO_WAV\n", stderr)
            exit(2)
        }
        let decoder = try StreamingDecoder(model: CommandLine.arguments[1])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard file.processingFormat.sampleRate == 16000,
              file.processingFormat.channelCount == 1 else {
            fputs("Probe requires a 16 kHz mono sample\n", stderr)
            exit(2)
        }
        let frames: AVAudioFrameCount = 1600
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            decoder.feed(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
        decoder.finish()
        let (text, _, _) = decoder.result()
        print(text)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { exit(1) }
    }
}
