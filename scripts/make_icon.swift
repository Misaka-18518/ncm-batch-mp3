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

for variant in variants {
    let size = NSSize(width: variant.pixels, height: variant.pixels)
    let image = NSImage(size: size)
    image.lockFocus()

    let bounds = NSRect(origin: .zero, size: size)
    let corner = max(4, variant.pixels * 0.22)
    let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: variant.pixels * 0.04, dy: variant.pixels * 0.04), xRadius: corner, yRadius: corner)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.82, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.67, blue: 0.55, alpha: 1)
    ])
    gradient?.draw(in: rounded, angle: -35)

    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    rounded.lineWidth = max(1, variant.pixels * 0.018)
    rounded.stroke()

    let discRect = NSRect(
        x: variant.pixels * 0.18,
        y: variant.pixels * 0.18,
        width: variant.pixels * 0.64,
        height: variant.pixels * 0.64
    )
    NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
    NSBezierPath(ovalIn: discRect).fill()

    NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(ovalIn: discRect.insetBy(dx: variant.pixels * 0.22, dy: variant.pixels * 0.22)).fill()

    let noteFont = NSFont.systemFont(ofSize: variant.pixels * 0.44, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: noteFont,
        .foregroundColor: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.25, alpha: 1)
    ]
    let note = "♪" as NSString
    let noteSize = note.size(withAttributes: attrs)
    note.draw(
        at: NSPoint(x: variant.pixels * 0.50 - noteSize.width * 0.5, y: variant.pixels * 0.44 - noteSize.height * 0.5),
        withAttributes: attrs
    )

    let mp3Attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: max(7, variant.pixels * 0.13), weight: .bold),
        .foregroundColor: NSColor.white
    ]
    let mp3 = "MP3" as NSString
    let mp3Size = mp3.size(withAttributes: mp3Attrs)
    mp3.draw(
        at: NSPoint(x: variant.pixels * 0.5 - mp3Size.width * 0.5, y: variant.pixels * 0.10),
        withAttributes: mp3Attrs
    )

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render icon")
    }
    try png.write(to: output.appendingPathComponent(variant.name))
}
