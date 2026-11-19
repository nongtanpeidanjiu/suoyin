// Renders the application icon into an .iconset folder.
// Usage: swift make-icon.swift <output.iconset>
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // Plate: macOS icon grid (824 square, 100 inset), continuous-looking corners.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(platePath)
    ctx.setFillColor(NSColor(srgbRed: 0.955, green: 0.945, blue: 0.925, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.985, green: 0.98, blue: 0.97, alpha: 1).cgColor,
        NSColor(srgbRed: 0.90, green: 0.885, blue: 0.86, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()

    // List rows.
    func row(_ y: CGFloat, _ width: CGFloat, _ color: NSColor) {
        let r = CGRect(x: 250, y: y, width: width, height: 58)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 29, cornerHeight: 29, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
    let quiet = NSColor(srgbRed: 0.76, green: 0.745, blue: 0.715, alpha: 1)
    row(318, 330, quiet)
    row(452, 430, NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1))
    row(586, 270, quiet)

    // Magnifier.
    let ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22,
                  color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(74)
    ctx.move(to: CGPoint(x: 668, y: 668))
    ctx.addLine(to: CGPoint(x: 772, y: 772))
    ctx.strokePath()
    ctx.setLineWidth(58)
    ctx.strokeEllipse(in: CGRect(x: 340, y: 300, width: 390, height: 390))
    ctx.restoreGState()
    // Lens tint so rows read as "under glass".
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    ctx.fillEllipse(in: CGRect(x: 369, y: 329, width: 332, height: 332))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = drawIcon(size: CGFloat(points * scale))
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
