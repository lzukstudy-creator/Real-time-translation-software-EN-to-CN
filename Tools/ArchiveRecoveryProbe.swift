import Darwin
import Foundation

@main
enum ArchiveRecoveryProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let staging = root.appendingPathComponent("staging")
        let finished = root.appendingPathComponent("finished")
        if CommandLine.arguments[1] == "write" {
            let archive = try BilingualArchive(stagingDirectory: staging,
                                               destinationDirectory: finished)
            archive.setEnglish("Foreign key is an important database term.")
            let firstDeadline = Date().addingTimeInterval(4)
            var englishPersisted = false
            while Date() < firstDeadline {
                if let saved = try? String(contentsOf: archive.destinationURL, encoding: .utf8),
                   saved.contains("Foreign key is an important database term.") {
                    englishPersisted = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard englishPersisted else { fatalError("Periodic English save did not run") }
            archive.setTranslation(segment: 0, seconds: 1,
                                   english: "Foreign key is an important database term.",
                                   chinese: "外键是一个重要的数据库术语。")
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                if let saved = try? String(contentsOf: archive.destinationURL, encoding: .utf8),
                   saved.contains("外键是一个重要的数据库术语。") {
                    print("Live automatic copy exists before stopping")
                    fflush(stdout)
                    _exit(0)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            fatalError("Live automatic copy was not written")
        }
        if CommandLine.arguments[1] == "recover" {
            let recovered = BilingualArchive.recover(staging: staging, destination: finished)
            guard recovered.count == 1,
                  let saved = try? String(contentsOf: recovered[0], encoding: .utf8),
                  saved.contains("外键是一个重要的数据库术语。") else {
                fatalError("Automatic recovery failed")
            }
            print("Interrupted session recovered without a normal stop")
            return
        }
        if CommandLine.arguments[1] == "finish" {
            let archive = try BilingualArchive(stagingDirectory: staging,
                                               destinationDirectory: finished)
            archive.setEnglish("A completed session remains on disk.")
            archive.setSummary("演讲总结\n整体内容\n数据库设计。\n\n重点\n1. 外键。")
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<URL, Error>?
            archive.finish(reason: "正常结束") { result = $0; semaphore.signal() }
            guard semaphore.wait(timeout: .now() + 5) == .success,
                  let output = try result?.get(),
                  output == archive.destinationURL,
                  !FileManager.default.fileExists(atPath: archive.stagingURL.path),
                  try String(contentsOf: output, encoding: .utf8)
                    .contains("A completed session remains on disk."),
                  try String(contentsOf: output, encoding: .utf8)
                    .contains("演讲总结") else {
                fatalError("Normal finish did not retain the completed transcript")
            }
            print("Normal stop keeps the live copy and removes the recovery copy")
            return
        }
        exit(2)
    }
}
