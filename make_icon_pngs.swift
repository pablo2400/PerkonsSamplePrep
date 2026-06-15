import AppKit

let source = URL(fileURLWithPath: "/Users/pawel/Downloads/Perkons_1_2.png")
let output = URL(fileURLWithPath: "/Users/pawel/PerkonsSamplePrep/AppIcon.iconset")
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

guard let image = NSImage(contentsOf: source),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read source image")
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let imageWidth = CGFloat(cgImage.width)
let imageHeight = CGFloat(cgImage.height)
let deviceCrop = CGRect(
    x: imageWidth * 0.08,
    y: imageHeight * 0.30,
    width: imageWidth * 0.84,
    height: imageHeight * 0.42
)

for (name, size) in sizes {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let sizeValue = CGFloat(size)
    let iconRect = rect.insetBy(dx: sizeValue * 0.22, dy: sizeValue * 0.22)
    let cornerRadius = sizeValue * 0.08
    let deviceRect = iconRect.insetBy(dx: sizeValue * 0.02, dy: sizeValue * 0.02)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    rect.fill()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = max(1, sizeValue * 0.025)
    shadow.shadowOffset = NSSize(width: 0, height: -sizeValue * 0.012)
    shadow.set()

    let plate = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.current?.cgContext.saveGState()
    plate.addClip()
    if let cropped = cgImage.cropping(to: deviceCrop) {
        let croppedImage = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        let croppedSize = croppedImage.size
        let scale = max(deviceRect.width / croppedSize.width, deviceRect.height / croppedSize.height)
        let drawSize = NSSize(width: croppedSize.width * scale, height: croppedSize.height * scale)
        let drawRect = NSRect(
            x: deviceRect.midX - drawSize.width / 2,
            y: deviceRect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        croppedImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    NSGraphicsContext.current?.cgContext.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent(name))
}
