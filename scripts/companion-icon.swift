// Draws the Voice Companion app icon: a glowing voice orb on a dark rounded square.
//
//   swift scripts/companion-icon.swift <out.iconset>
//   iconutil -c icns <out.iconset> -o Packaging/VoiceCompanion/AppIcon.icns
//
// Every size is drawn straight into a bitmap of its exact pixel size, so @2x files
// are real 2x pixels. Geometry is in a 1024-unit space and follows the macOS icon
// grid: an 824-unit rounded square centred on the canvas, transparent margin around it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/companion-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

/// A radial blob that fades from `color` at its centre to transparent at `radius`.
func blob(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ color: CGColor, falloff: CGFloat = 1) {
    let clear = color.copy(alpha: 0)!
    ctx.drawRadialGradient(
        gradient([(color, 0), (color.copy(alpha: color.alpha * 0.45)!, 0.55 * falloff), (clear, 1)]),
        startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// `pixelsPerUnit` scales the shadow, which Core Graphics applies in device pixels, not user space.
func draw(_ ctx: CGContext, pixelsPerUnit: CGFloat) {
    let canvas: CGFloat = 1024
    let content: CGFloat = 824
    let inset = (canvas - content) / 2
    let tile = CGRect(x: inset, y: inset, width: content, height: content)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: content * 0.225, cornerHeight: content * 0.225, transform: nil)

    // Drop shadow under the tile, inside the transparent margin.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * pixelsPerUnit), blur: 28 * pixelsPerUnit, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0.06, 0.07, 0.11))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: dark vertical gradient, clipped to the rounded square for everything that follows.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(rgb(0.090, 0.098, 0.165), 0), (rgb(0.024, 0.027, 0.055), 1)]),
        start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    let c = CGPoint(x: canvas / 2, y: canvas / 2 + 6)
    let r: CGFloat = 292

    // Halo hugging the orb's edge and fading out before the tile corners, then two faint
    // ripples: the orb is speaking.
    ctx.setBlendMode(.screen)
    for (reach, color) in [
        (1.62, rgb(0.38, 0.45, 1.00, 0.55)),
        (1.45, rgb(0.62, 0.34, 0.98, 0.30)),
        (1.32, rgb(0.12, 0.80, 0.78, 0.22)),
    ] as [(CGFloat, CGColor)] {
        ctx.drawRadialGradient(
            gradient([(color, 0), (color.copy(alpha: color.alpha * 0.35)!, 0.35), (color.copy(alpha: 0)!, 1)]),
            startCenter: c, startRadius: r * 0.95, endCenter: c, endRadius: r * reach, options: [])
    }
    ctx.setBlendMode(.normal)
    for (scale, width, alpha) in [(1.22, 4.0, 0.13), (1.46, 3.0, 0.06)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.setStrokeColor(rgb(0.70, 0.74, 1.00, alpha))
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: CGRect(x: c.x - r * scale, y: c.y - r * scale, width: 2 * r * scale, height: 2 * r * scale))
    }

    // The orb: a deep indigo body lit by blue, violet and teal blobs.
    let orb = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.addEllipse(in: orb)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(rgb(0.16, 0.15, 0.40), 0), (rgb(0.06, 0.06, 0.18), 1)]),
        startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    ctx.setBlendMode(.screen)
    blob(ctx, CGPoint(x: c.x - r * 0.32, y: c.y + r * 0.22), r * 0.95, rgb(0.22, 0.52, 1.00, 0.95))
    blob(ctx, CGPoint(x: c.x + r * 0.38, y: c.y - r * 0.08), r * 0.90, rgb(0.62, 0.34, 0.98, 0.95))
    blob(ctx, CGPoint(x: c.x - r * 0.10, y: c.y - r * 0.48), r * 0.80, rgb(0.12, 0.84, 0.76, 0.85))
    blob(ctx, CGPoint(x: c.x + r * 0.05, y: c.y + r * 0.05), r * 0.50, rgb(0.80, 0.78, 1.00, 0.22))
    ctx.setBlendMode(.normal)
    // Light gathers at the edge, as in a lit glass sphere: dim the body just inside the rim,
    // then a luminous band on the rim itself.
    ctx.drawRadialGradient(
        gradient([(rgb(0, 0, 0.05, 0), 0.62), (rgb(0, 0, 0.05, 0.22), 0.90), (rgb(0, 0, 0.05, 0), 1)]),
        startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    ctx.setBlendMode(.screen)
    ctx.drawRadialGradient(
        gradient([(rgb(0.55, 0.62, 1.00, 0), 0.86), (rgb(0.55, 0.62, 1.00, 0.45), 1)]),
        startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    ctx.setBlendMode(.normal)
    // Specular highlight, upper left, squashed into an ellipse.
    ctx.saveGState()
    let spot = CGPoint(x: c.x - r * 0.34, y: c.y + r * 0.48)
    ctx.translateBy(x: spot.x, y: spot.y)
    ctx.rotate(by: .pi / 7)
    ctx.scaleBy(x: 1.0, y: 0.62)
    ctx.setBlendMode(.screen)
    blob(ctx, .zero, r * 0.42, rgb(1, 1, 1, 0.70), falloff: 0.7)
    ctx.restoreGState()
    ctx.restoreGState()

    // Rim light.
    ctx.setStrokeColor(rgb(0.85, 0.88, 1.00, 0.22))
    ctx.setLineWidth(3)
    ctx.strokeEllipse(in: orb.insetBy(dx: 1.5, dy: 1.5))
    ctx.restoreGState()

    // A hairline on the tile edge so it holds against a dark Dock.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("cannot create a \(px)px bitmap") }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx, pixelsPerUnit: CGFloat(px) / 1024)
    let url = outDir.appendingPathComponent("\(name).png")
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot finalize \(url.path)") }
    print("\(url.lastPathComponent) \(px)x\(px)")
}
