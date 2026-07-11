import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

struct IconVariant {
    let name: String
    let pixels: CGFloat
}

let variants: [IconVariant] = [
    .init(name: "icon_16x16.png", pixels: 16),
    .init(name: "icon_16x16@2x.png", pixels: 32),
    .init(name: "icon_32x32.png", pixels: 32),
    .init(name: "icon_32x32@2x.png", pixels: 64),
    .init(name: "icon_128x128.png", pixels: 128),
    .init(name: "icon_128x128@2x.png", pixels: 256),
    .init(name: "icon_256x256.png", pixels: 256),
    .init(name: "icon_256x256@2x.png", pixels: 512),
    .init(name: "icon_512x512.png", pixels: 512),
    .init(name: "icon_512x512@2x.png", pixels: 1024)
]

func c(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawText(_ text: String, pixels: CGFloat, center: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    guard pixels >= 64 else { return }
    let string = text as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    let textSize = string.size(withAttributes: attrs)
    string.draw(
        at: NSPoint(x: center.x - textSize.width * 0.5, y: center.y - textSize.height * 0.5),
        withAttributes: attrs
    )
}

func drawArrow(from start: NSPoint, to end: NSPoint, width: CGFloat, color: NSColor) {
    color.setStroke()
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: start)
    path.line(to: end)
    path.stroke()

    color.setFill()
    let head = NSBezierPath()
    let headSize = width * 2.8
    head.move(to: end)
    head.line(to: NSPoint(x: end.x - headSize, y: end.y + headSize * 0.64))
    head.line(to: NSPoint(x: end.x - headSize * 0.58, y: end.y))
    head.line(to: NSPoint(x: end.x - headSize, y: end.y - headSize * 0.64))
    head.close()
    head.fill()
}

for variant in variants {
    let p = variant.pixels
    let image = NSImage(size: NSSize(width: p, height: p))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: p, height: p)
    let outer = bounds.insetBy(dx: p * 0.035, dy: p * 0.035)
    let outerPath = rounded(outer, p * 0.235)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -p * 0.026)
    shadow.shadowBlurRadius = p * 0.055
    shadow.set()
    c(0.04, 0.09, 0.12).setFill()
    outerPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    outerPath.addClip()
    NSGradient(colors: [
        c(0.08, 0.38, 0.72),
        c(0.03, 0.70, 0.61),
        c(0.98, 0.55, 0.35)
    ])?.draw(in: bounds, angle: -34)

    c(1, 1, 1, 0.20).setFill()
    rounded(NSRect(x: p * 0.10, y: p * 0.64, width: p * 0.70, height: p * 0.20), p * 0.10).fill()
    c(0, 0, 0, 0.10).setFill()
    rounded(NSRect(x: p * 0.17, y: p * 0.08, width: p * 0.74, height: p * 0.21), p * 0.10).fill()
    NSGraphicsContext.restoreGraphicsState()

    c(1, 1, 1, 0.35).setStroke()
    outerPath.lineWidth = max(1, p * 0.012)
    outerPath.stroke()

    let glassRect = NSRect(x: p * 0.13, y: p * 0.18, width: p * 0.74, height: p * 0.60)
    let glassPath = rounded(glassRect, p * 0.14)
    NSGraphicsContext.saveGraphicsState()
    let glassShadow = NSShadow()
    glassShadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    glassShadow.shadowOffset = NSSize(width: 0, height: -p * 0.012)
    glassShadow.shadowBlurRadius = p * 0.030
    glassShadow.set()
    c(1, 1, 1, 0.46).setFill()
    glassPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    c(1, 1, 1, 0.55).setStroke()
    glassPath.lineWidth = max(1, p * 0.010)
    glassPath.stroke()

    let discRect = NSRect(x: p * 0.19, y: p * 0.29, width: p * 0.36, height: p * 0.36)
    c(1, 1, 1, 0.88).setFill()
    NSBezierPath(ovalIn: discRect).fill()
    c(0.04, 0.17, 0.20, 0.92).setFill()
    NSBezierPath(ovalIn: discRect.insetBy(dx: p * 0.115, dy: p * 0.115)).fill()
    c(0.05, 0.70, 0.63, 0.34).setStroke()
    let groove = NSBezierPath(ovalIn: discRect.insetBy(dx: p * 0.055, dy: p * 0.055))
    groove.lineWidth = max(1, p * 0.008)
    groove.stroke()

    let note = "♪" as NSString
    let noteAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: p * 0.20, weight: .bold),
        .foregroundColor: c(1, 1, 1, 0.96)
    ]
    let noteSize = note.size(withAttributes: noteAttrs)
    if p >= 64 {
        note.draw(
            at: NSPoint(x: discRect.midX - noteSize.width * 0.5, y: discRect.midY - noteSize.height * 0.43),
            withAttributes: noteAttrs
        )
    }

    let fileRect = NSRect(x: p * 0.54, y: p * 0.34, width: p * 0.27, height: p * 0.28)
    let filePath = rounded(fileRect, p * 0.055)
    c(0.03, 0.11, 0.16, 0.72).setFill()
    filePath.fill()
    c(1, 1, 1, 0.33).setStroke()
    filePath.lineWidth = max(1, p * 0.008)
    filePath.stroke()
    drawText("NCM", pixels: p, center: NSPoint(x: fileRect.midX, y: fileRect.midY + p * 0.045), size: p * 0.042, weight: .bold, color: .white)
    drawText("MP3", pixels: p, center: NSPoint(x: fileRect.midX, y: fileRect.midY - p * 0.045), size: p * 0.048, weight: .heavy, color: c(0.75, 1.0, 0.95))

    drawArrow(
        from: NSPoint(x: p * 0.47, y: p * 0.48),
        to: NSPoint(x: p * 0.61, y: p * 0.48),
        width: max(1.2, p * 0.018),
        color: c(0.72, 1.0, 0.96, 0.92)
    )

    let waveform = NSBezierPath()
    waveform.lineWidth = max(1, p * 0.012)
    waveform.lineCapStyle = .round
    c(1, 1, 1, 0.72).setStroke()
    let y = p * 0.245
    for index in 0..<5 {
        let x = p * (0.28 + CGFloat(index) * 0.075)
        waveform.move(to: NSPoint(x: x, y: y - p * 0.025))
        waveform.line(to: NSPoint(x: x, y: y + p * (0.020 + CGFloat(index % 3) * 0.018)))
    }
    waveform.stroke()

    let shine = NSBezierPath()
    shine.lineWidth = max(1, p * 0.010)
    shine.lineCapStyle = .round
    c(1, 1, 1, 0.40).setStroke()
    shine.move(to: NSPoint(x: p * 0.24, y: p * 0.71))
    shine.line(to: NSPoint(x: p * 0.58, y: p * 0.78))
    shine.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render icon")
    }
    try png.write(to: output.appendingPathComponent(variant.name))
}
