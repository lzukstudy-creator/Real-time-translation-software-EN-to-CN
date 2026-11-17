import AppKit
import Foundation

@main
enum AppIconProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let icon = NSWorkspace.shared.icon(forFile: CommandLine.arguments[1])
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: 512, pixelsHigh: 512,
                                           bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Finder could not return an icon")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        icon.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Finder icon export failed")
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Finder icon exported")
    }
}
