// 生成应用图标的 .iconset 目录。
// 用法：swift make-icon.swift <output.iconset>
//
// 128 像素及以上用完整画法（玻璃镜片、高光、投影）；
// 16、32、64 像素用单独的简化画法，线条对齐像素格。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

// 连续曲率圆角矩形（与系统图标底板同一种圆角，参数取自常见的逆向数值）。
func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let p = CGMutablePath()
    // 以右上角为模板，其余三个角按对称变换得到。坐标系 y 向下。
    let corner: [(CGFloat, CGFloat)] = [
        (1.52866471, 0), (1.08849323, 0), (0.86840689, 0), (0.63149399, 0.07491139),
        (0.37282392, 0.16905899), (0.16905899, 0.37282392), (0.07491176, 0.63149399),
        (0, 0.86840689), (0, 1.08849323), (0, 1.52866483),
    ]
    // 每个角：给出角点和“沿边向内”的两个方向。
    let corners: [(CGPoint, CGFloat, CGFloat, Bool)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), -1, 1, false),  // 右上
        (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1, true),  // 右下
        (CGPoint(x: rect.minX, y: rect.maxY), 1, -1, false),  // 左下
        (CGPoint(x: rect.minX, y: rect.minY), 1, 1, true),    // 左上
    ]
    for (i, (c, sx, sy, swap)) in corners.enumerated() {
        let pts = corner.map { (u, v) -> CGPoint in
            let (a, b) = swap ? (v, u) : (u, v)
            return CGPoint(x: c.x + sx * a * r, y: c.y + sy * b * r)
        }
        if i == 0 { p.move(to: pts[0]) } else { p.addLine(to: pts[0]) }
        p.addCurve(to: pts[3], control1: pts[1], control2: pts[2])
        p.addCurve(to: pts[6], control1: pts[4], control2: pts[5])
        p.addCurve(to: pts[9], control1: pts[7], control2: pts[8])
    }
    p.closeSubpath()
    return p
}

func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

// 阴影的偏移和模糊以设备像素计，且设备坐标 y 向上：向下偏移要写负值。
func shadow(_ ctx: CGContext, scale s: CGFloat, down: CGFloat, blur: CGFloat, alpha: CGFloat) {
    ctx.setShadow(offset: CGSize(width: 0, height: -down * s), blur: blur * s,
                  color: rgb(0, 0, 0, alpha))
}

// 柔边填充：把形状画到画布外，只让它的阴影落回原位，得到边缘模糊的形状。
func softFill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, blur: CGFloat, scale s: CGFloat) {
    let off: CGFloat = 4000
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: off * s, height: 0), blur: blur * s, color: color)
    ctx.translateBy(x: -off, y: 0)
    ctx.addPath(path)
    ctx.setFillColor(rgb(0, 0, 0, 1))
    ctx.fillPath()
    ctx.restoreGState()
}

// 共用配色
let plateTop = rgb(0.985, 0.982, 0.972)
let plateBottom = rgb(0.905, 0.893, 0.872)
let quiet = rgb(0.755, 0.743, 0.722)
let blue = rgb(0.039, 0.518, 1.0)          // #0A84FF
let ink = rgb(0.155, 0.155, 0.168)
let inkLight = rgb(0.30, 0.30, 0.32)

func drawPlate(_ ctx: CGContext, _ path: CGPath, s: CGFloat, down: CGFloat, blur: CGFloat,
               alpha: CGFloat, top: CGFloat, bottom: CGFloat) {
    ctx.saveGState()
    shadow(ctx, scale: s, down: down, blur: blur, alpha: alpha)
    ctx.addPath(path)
    ctx.setFillColor(plateBottom)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, plateTop), (1, plateBottom)]),
                           start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
}

// MARK: - 完整画法（1024 设计稿，按比例缩放）

func drawFull(_ px: Int) -> CGImage {
    let ctx = makeContext(px)
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // 底板：824 见方，四周留 100。
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = continuousRect(plate, radius: 185)
    drawPlate(ctx, platePath, s: s, down: 10, blur: 20, alpha: 0.28, top: 100, bottom: 924)

    // 顶部边缘的高光内描边：沿底板边缘描一圈，再用由上到下淡出的渐变上色。
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    ctx.addPath(platePath)
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 1)), (0.35, rgb(1, 1, 1, 0.35)), (1, rgb(1, 1, 1, 0))]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 520), options: [])
    ctx.restoreGState()

    // 清单
    struct Row { var rect: CGRect; var color: CGColor; var lens: CGColor }
    let rowH: CGFloat = 58
    let rows = [
        Row(rect: CGRect(x: 250, y: 318, width: 330, height: rowH), color: quiet,
            lens: rgb(0.785, 0.775, 0.755)),
        Row(rect: CGRect(x: 250, y: 452, width: 400, height: rowH), color: blue,
            lens: rgb(0.16, 0.60, 1.0)),
        Row(rect: CGRect(x: 250, y: 586, width: 270, height: rowH), color: quiet,
            lens: rgb(0.785, 0.775, 0.755)),
    ]
    func fillRow(_ r: CGRect, _ c: CGColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.setFillColor(c)
        ctx.fillPath()
    }
    for r in rows { fillRow(r.rect, r.color) }

    // 放大镜几何
    let c = CGPoint(x: 532, y: 492)        // 镜片中心
    let ringR: CGFloat = 192               // 镜框中线半径
    let ringW: CGFloat = 52
    let innerR = ringR - ringW / 2
    let outerR = ringR + ringW / 2
    let d = 1 / CGFloat(2).squareRoot()
    let handleStart = CGPoint(x: c.x + (outerR - 6) * d, y: c.y + (outerR - 6) * d)
    let handleEnd = CGPoint(x: 770, y: 730)
    let handleW: CGFloat = 76
    let handleEndAdj = CGPoint(x: handleEnd.x, y: handleEnd.x - c.x + c.y)  // 保持 45°
    let handlePath = CGMutablePath()
    handlePath.move(to: handleStart)
    handlePath.addLine(to: handleEndAdj)
    let handleShape = handlePath.copy(strokingWithWidth: handleW, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let discRect = CGRect(x: c.x - outerR, y: c.y - outerR, width: outerR * 2, height: outerR * 2)
    let innerRect = CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2)

    // 整只放大镜在底板上的淡投影（镜片处的阴影会被下面的玻璃内部覆盖，只在外沿露出）。
    ctx.saveGState()
    shadow(ctx, scale: s, down: 14, blur: 26, alpha: 0.22)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(ink)
    ctx.addEllipse(in: discRect)
    ctx.addPath(handleShape)
    ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // 玻璃内部
    ctx.saveGState()
    ctx.addEllipse(in: innerRect)
    ctx.clip()
    // 先铺回底板，盖掉原清单和投影
    ctx.drawLinearGradient(gradient([(0, plateTop), (1, plateBottom)]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    // 镜片在底板上的极淡阴影（玻璃略带厚度，镜片下沿内侧略暗）
    ctx.drawRadialGradient(gradient([(0, rgb(0, 0, 0, 0)), (0.82, rgb(0, 0, 0, 0)), (1, rgb(0, 0, 0, 0.07))]),
                           startCenter: CGPoint(x: c.x, y: c.y - 10), startRadius: 0,
                           endCenter: CGPoint(x: c.x, y: c.y - 10), endRadius: innerR + 10, options: [])
    // 放大后的清单
    let mag: CGFloat = 1.16
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.scaleBy(x: mag, y: mag)
    ctx.translateBy(x: -c.x, y: -c.y)
    for r in rows { fillRow(r.rect, r.lens) }
    ctx.restoreGState()
    // 极淡的白色径向渐变：中心偏左上最亮
    let glow = CGPoint(x: c.x - innerR * 0.25, y: c.y - innerR * 0.3)
    ctx.drawRadialGradient(gradient([(0, rgb(1, 1, 1, 0.20)), (0.6, rgb(1, 1, 1, 0.08)), (1, rgb(1, 1, 1, 0.02))]),
                           startCenter: glow, startRadius: 0, endCenter: c, endRadius: innerR, options: [])
    // 右下内沿一道细亮边（光从玻璃里透出来）
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(5)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.55))
    ctx.addArc(center: c, radius: innerR - 7, startAngle: .pi * 0.05, endAngle: .pi * 0.45, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
    // 左上弧形高光：两圆相减得到月牙，柔边填充，再叠一道更窄更亮的
    func crescent(_ r1: CGFloat, _ r2: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CGPath {
        let a = CGPath(ellipseIn: CGRect(x: c.x - r1, y: c.y - r1, width: r1 * 2, height: r1 * 2), transform: nil)
        let bc = CGPoint(x: c.x + dx, y: c.y + dy)
        let b = CGPath(ellipseIn: CGRect(x: bc.x - r2, y: bc.y - r2, width: r2 * 2, height: r2 * 2), transform: nil)
        return a.subtracting(b)
    }
    softFill(ctx, crescent(innerR - 16, innerR - 8, 20, 34), rgb(1, 1, 1, 0.32), blur: 14, scale: s)
    softFill(ctx, crescent(innerR - 26, innerR - 24, 12, 26), rgb(1, 1, 1, 0.55), blur: 5, scale: s)
    ctx.restoreGState()

    // 镜框和手柄：分别裁剪后用同一道渐变上色
    let inkGrad = gradient([(0, inkLight), (0.45, ink), (1, rgb(0.11, 0.11, 0.12))])
    let gStart = CGPoint(x: c.x - outerR, y: c.y - outerR)
    let gEnd = CGPoint(x: handleEndAdj.x + handleW / 2, y: handleEndAdj.y + handleW / 2)
    for clip in [{ ctx.addPath(handleShape); ctx.clip() }, {
        ctx.addEllipse(in: discRect); ctx.addEllipse(in: innerRect); ctx.clip(using: .evenOdd)
    }] as [() -> Void] {
        ctx.saveGState()
        clip()
        ctx.drawLinearGradient(inkGrad, start: gStart, end: gEnd, options: [])
        ctx.restoreGState()
    }
    // 镜框外沿和内沿各一道很淡的亮边，左上最亮、向右下淡出，给镜框一点体积
    for (r, w) in [(outerR, 7.0), (innerR, 5.0)] as [(CGFloat, CGFloat)] {
        ctx.saveGState()
        ctx.addEllipse(in: discRect)
        ctx.addEllipse(in: innerRect)
        ctx.clip(using: .evenOdd)
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.setLineWidth(w * 2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.22)), (0.5, rgb(1, 1, 1, 0))]),
                               start: CGPoint(x: c.x - outerR * 0.75, y: c.y - outerR * 0.75),
                               end: CGPoint(x: c.x + outerR * 0.75, y: c.y + outerR * 0.75), options: [])
        ctx.restoreGState()
    }

    return ctx.makeImage()!
}

// MARK: - 小尺寸简化画法（直接以目标像素为单位）

struct Small {
    var plateInset: CGFloat
    var plateRadius: CGFloat
    var shadowDown: CGFloat, shadowBlur: CGFloat, shadowAlpha: CGFloat
    var lens: CGPoint            // 镜片中心
    var ringR: CGFloat           // 镜框中线半径
    var ringW: CGFloat
    var handleEnd: CGFloat       // 手柄末端（45° 线上，x = y 偏移）
    var handleW: CGFloat
    var blueBar: CGRect
    var grayBars: [CGRect]
    var tint: Bool
}

let smallSpecs: [Int: Small] = [
    16: Small(plateInset: 1, plateRadius: 3.6, shadowDown: 0.5, shadowBlur: 0.8, shadowAlpha: 0.2,
              lens: CGPoint(x: 8, y: 7), ringR: 3, ringW: 2,
              handleEnd: 13, handleW: 2.2,
              blueBar: CGRect(x: 2, y: 6, width: 8, height: 2),
              grayBars: [], tint: false),
    32: Small(plateInset: 3, plateRadius: 6.6, shadowDown: 0.6, shadowBlur: 1.2, shadowAlpha: 0.28,
              lens: CGPoint(x: 17, y: 14), ringR: 6.5, ringW: 3,
              handleEnd: 25.5, handleW: 4,
              blueBar: CGRect(x: 6, y: 12, width: 17, height: 4),
              grayBars: [CGRect(x: 6, y: 7, width: 5, height: 2), CGRect(x: 6, y: 19, width: 4, height: 2)],
              tint: false),
    64: Small(plateInset: 6, plateRadius: 11.6, shadowDown: 1, shadowBlur: 2, shadowAlpha: 0.30,
              lens: CGPoint(x: 34, y: 30), ringR: 13, ringW: 6,
              handleEnd: 51, handleW: 7,
              blueBar: CGRect(x: 13, y: 27, width: 33, height: 6),
              grayBars: [CGRect(x: 13, y: 16, width: 16, height: 4), CGRect(x: 13, y: 40, width: 12, height: 4)],
              tint: true),
]

func drawSmall(_ px: Int, _ sp: Small) -> CGImage {
    let ctx = makeContext(px)
    let n = CGFloat(px)
    ctx.translateBy(x: 0, y: n)
    ctx.scaleBy(x: 1, y: -1)

    let plate = CGRect(x: sp.plateInset, y: sp.plateInset, width: n - 2 * sp.plateInset, height: n - 2 * sp.plateInset)
    let platePath = continuousRect(plate, radius: sp.plateRadius)
    drawPlate(ctx, platePath, s: 1, down: sp.shadowDown, blur: sp.shadowBlur, alpha: sp.shadowAlpha,
              top: plate.minY, bottom: plate.maxY)

    func bar(_ r: CGRect, _ col: CGColor) {
        let rad = r.height <= 2 ? 0 : r.height / 2
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(col)
        ctx.fillPath()
    }
    for g in sp.grayBars { bar(g, quiet) }
    bar(sp.blueBar, blue)

    let c = sp.lens
    let innerR = sp.ringR - sp.ringW / 2
    if sp.tint {
        ctx.setFillColor(rgb(1, 1, 1, 0.14))
        ctx.fillEllipse(in: CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2))
    }
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(sp.ringW)
    ctx.strokeEllipse(in: CGRect(x: c.x - sp.ringR, y: c.y - sp.ringR, width: sp.ringR * 2, height: sp.ringR * 2))
    let d = 1 / CGFloat(2).squareRoot()
    let start = sp.ringR * d
    ctx.setLineCap(.round)
    ctx.setLineWidth(sp.handleW)
    ctx.move(to: CGPoint(x: c.x + start, y: c.y + start))
    ctx.addLine(to: CGPoint(x: c.x + (sp.handleEnd - c.x), y: c.y + (sp.handleEnd - c.x)))
    ctx.strokePath()
    return ctx.makeImage()!
}

func render(_ px: Int) -> CGImage {
    if let sp = smallSpecs[px] { return drawSmall(px, sp) }
    return drawFull(px)
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    writePNG(render(points * scale), out.appendingPathComponent(name))
}
