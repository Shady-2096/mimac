// Generates the Mimac app icon set: an ember bolt on a warm charcoal squircle.
// Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-icon.swift <output.iconset>\n", stderr)
    exit(64)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let variants: [(pixels: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let size = CGFloat(pixels)
    // Apple's icon grid: the squircle fills ~82% of the canvas with a transparent margin.
    let inset = size * 0.09
    let plate = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let plateRadius = plate.width * 0.225
    let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)
    platePath.addClip()

    NSGradient(
        starting: NSColor(srgbRed: 0.165, green: 0.157, blue: 0.145, alpha: 1),
        ending: NSColor(srgbRed: 0.07, green: 0.066, blue: 0.06, alpha: 1)
    )!.draw(in: plate, angle: -90)

    // Soft ember glow rising from the bottom of the plate.
    NSGradient(colors: [
        NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 0.34),
        NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 0),
    ])!.draw(
        fromCenter: NSPoint(x: plate.midX, y: plate.minY + plate.height * 0.08), radius: 0,
        toCenter: NSPoint(x: plate.midX, y: plate.minY + plate.height * 0.08), radius: plate.width * 0.85,
        options: []
    )

    let config = NSImage.SymbolConfiguration(pointSize: plate.width * 0.46, weight: .semibold)
    if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: bolt.size, flipped: false) { rect in
            bolt.draw(in: rect)
            NSColor(srgbRed: 0.96, green: 0.66, blue: 0.16, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let target = NSRect(
            x: plate.midX - bolt.size.width / 2,
            y: plate.midY - bolt.size.height / 2,
            width: bolt.size.width,
            height: bolt.size.height
        )
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for variant in variants {
    let data = render(pixels: variant.pixels)
    try data.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
}
print("Wrote \(variants.count) icon sizes to \(outputURL.path)")
