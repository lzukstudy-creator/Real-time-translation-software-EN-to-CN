import Foundation
import Darwin

struct TranslationRecord {
    let segment: Int
    let seconds: Double
    let english: String
    let chinese: String
}

final class BilingualArchive: @unchecked Sendable {
    let stagingURL: URL
    let destinationURL: URL
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "app.tingyi.archive", qos: .utility)
    private let started: Date
    private var currentURL: URL
    private var english = ""
    private var translations: [Int: TranslationRecord] = [:]
    private var summary: String?
    private var ended: String?
    private var closed = false
    private var failed: Error?
    private var lastWrite = 0.0
    private var dirty = false
    private var timer: DispatchSourceTimer?

    init(stagingDirectory: URL, destinationDirectory: URL, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let filename = "\(formatter.string(from: date))-\(UUID().uuidString.prefix(6)).txt"
        stagingURL = stagingDirectory.appendingPathComponent(filename)
        destinationURL = destinationDirectory.appendingPathComponent(filename)
        currentURL = stagingURL
        started = date
        try writeSnapshot()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.flushIfDue(force: true) }
        self.timer = timer
        timer.resume()
    }

    func setEnglish(_ text: String) {
        queue.async { [self] in
            guard !closed, english != text else { return }
            english = text
            dirty = true
            flushIfDue()
        }
    }

    func setTranslation(segment: Int, seconds: Double, english: String, chinese: String) {
        queue.async { [self] in
            guard !closed else { return }
            translations[segment] = TranslationRecord(segment: segment, seconds: seconds,
                                                      english: english, chinese: chinese)
            dirty = true
            flushIfDue(force: true)
        }
    }

    func setSummary(_ text: String) {
        queue.async { [self] in
            guard !closed else { return }
            summary = text
            dirty = true
            flushIfDue(force: true)
        }
    }

    func finish(reason: String, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            if closed {
                completion(failed.map(Result.failure) ?? .success(currentURL))
                return
            }
            timer?.cancel()
            timer = nil
            ended = "\(ISO8601DateFormatter().string(from: Date())) · \(reason)"
            dirty = true
            do {
                try writeSnapshot()
                try? FileManager.default.removeItem(at: stagingURL)
                currentURL = destinationURL
                closed = true
                completion(.success(currentURL))
            } catch {
                failed = error
                closed = true
                completion(.failure(error))
            }
        }
    }

    func export(to target: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                if !closed { try writeSnapshot() }
                if let failed { throw failed }
                if target.standardizedFileURL != currentURL.standardizedFileURL {
                    try Data(contentsOf: currentURL).write(to: target, options: .atomic)
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    @discardableResult
    static func recover(staging: URL, destination: URL) -> [URL] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) else { return [] }
        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var recovered: [URL] = []
        for file in files where file.pathExtension == "txt" {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            do {
                try Data(contentsOf: file).write(to: target, options: .atomic)
                try manager.removeItem(at: file)
                recovered.append(target)
            } catch { continue }
        }
        return recovered.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func flushIfDue(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard dirty, force || now - lastWrite >= 1 else { return }
        do { try writeSnapshot() }
        catch {
            let shouldReport = failed == nil
            failed = error
            if shouldReport { onError?(error) }
        }
    }

    private func writeSnapshot() throws {
        let snapshot = Data(document().utf8)
        try snapshot.write(to: stagingURL, options: .atomic)
        try snapshot.write(to: destinationURL, options: .atomic)
        let descriptor = Darwin.open(destinationURL.path, O_RDONLY)
        if descriptor >= 0 {
            _ = Darwin.fsync(descriptor)
            _ = Darwin.close(descriptor)
        }
        lastWrite = ProcessInfo.processInfo.systemUptime
        dirty = false
        failed = nil
    }

    private func document() -> String {
        var text = "课译 · 英中实时字幕\n开始：\(ISO8601DateFormatter().string(from: started))\n自动识别与翻译可能有误；不保存音频。\n\n"
        text += "英文全文\n\(english.isEmpty ? "（暂无字幕）" : english)\n\n中文翻译记录\n"
        if translations.isEmpty { text += "（暂无译文）\n" }
        for record in translations.values.sorted(by: { $0.segment < $1.segment }) {
            let minute = Int(record.seconds) / 60
            let second = Int(record.seconds) % 60
            text += String(format: "[%02d:%02d] 英文：%@\n         中文：%@\n\n",
                           minute, second, record.english, record.chinese)
        }
        if let summary, !summary.isEmpty { text += "\n\(summary)\n" }
        if let ended { text += "\n结束：\(ended)\n" }
        return text
    }
}
