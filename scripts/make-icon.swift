import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let dimension = CGFloat(pixels)
        let image = NSImage(size: NSSize(width: dimension, height: dimension))
        image.lockFocus()
        let inset = dimension * 0.085
        let bounds = NSRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
        NSColor(calibratedRed: 0.17, green: 0.38, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: dimension * 0.19, yRadius: dimension * 0.19).fill()
        let stroke = NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.88, alpha: 1)
        stroke.setStroke()
        let ring = NSBezierPath(
            ovalIn: NSRect(x: dimension * 0.24, y: dimension * 0.24, width: dimension * 0.52, height: dimension * 0.52))
        ring.lineWidth = dimension * 0.025
        ring.stroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: dimension * 0.36, y: dimension * 0.50))
        check.line(to: NSPoint(x: dimension * 0.46, y: dimension * 0.40))
        check.line(to: NSPoint(x: dimension * 0.65, y: dimension * 0.61))
        check.lineWidth = dimension * 0.047
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
