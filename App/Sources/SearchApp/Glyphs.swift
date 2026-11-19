import AppKit

enum MenuBarState {
    case idle
    case indexing(angle: CGFloat)
    case attention
}

enum Glyphs {
    /// Monochrome template image for the menu bar. Drawn on a 16-unit grid
    /// with y pointing down, matching the design source.
    static func menuBar(_ state: MenuBarState) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: side / 16, y: side / 16)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.4)
            ctx.setLineCap(.round)

            let center = CGPoint(x: 7, y: 7)
            switch state {
            case .indexing(let angle):
                // Open ring: three quarters of the lens, rotated.
                ctx.addArc(center: center, radius: 5, startAngle: angle,
                           endAngle: angle + .pi * 1.5, clockwise: false)
                ctx.strokePath()
            default:
                ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: 10, height: 10))
            }
            ctx.move(to: CGPoint(x: 10.8, y: 10.8))
            ctx.addLine(to: CGPoint(x: 14, y: 14))
            ctx.strokePath()

            switch state {
            case .attention:
                ctx.move(to: CGPoint(x: 7, y: 4.6))
                ctx.addLine(to: CGPoint(x: 7, y: 7.4))
                ctx.strokePath()
                ctx.fillEllipse(in: CGRect(x: 6.3, y: 8.7, width: 1.4, height: 1.4))
            case .indexing:
                ctx.setAlpha(0.5)
                fallthrough
            case .idle:
                ctx.move(to: CGPoint(x: 4.8, y: 6)); ctx.addLine(to: CGPoint(x: 9.2, y: 6))
                ctx.move(to: CGPoint(x: 4.8, y: 8)); ctx.addLine(to: CGPoint(x: 7.4, y: 8))
                ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let appear: TimeInterval = 0.14
    static let dismiss: TimeInterval = 0.12
    static let resize: TimeInterval = 0.18
    static let statusFade: TimeInterval = 0.15
}
