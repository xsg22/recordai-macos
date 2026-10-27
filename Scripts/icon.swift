import AppKit
let target = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.05, y: p * 0.05, width: p * 0.9, height: p * 0.9), xRadius: p * 0.2, yRadius: p * 0.2)
        NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.3, alpha: 1).setFill()
        background.fill()
        NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.85, alpha: 1).setFill()
        for (index, height) in [0.22, 0.42, 0.62, 0.36, 0.2].enumerated() {
            let h = p * height
            NSBezierPath(roundedRect: NSRect(x: p * (0.25 + Double(index) * 0.105), y: (p - h) / 2, width: p * 0.06, height: h), xRadius: p * 0.03, yRadius: p * 0.03).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(filename))
    }
}
