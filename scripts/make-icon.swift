// Draws AgentDE's app icon: a `>_` prompt with a small sparkle on a dark tile.
// Usage: swift scripts/make-icon.swift <out.png>   (1024×1024)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// The tile: macOS's icon grid leaves a margin around an 824-point rounded square.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0x2A2A30), color(0x141417)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// `>`: two strokes.
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(78)
ctx.setStrokeColor(color(0xF5F4EE))
ctx.move(to: CGPoint(x: 290, y: 640))
ctx.addLine(to: CGPoint(x: 470, y: 512))
ctx.addLine(to: CGPoint(x: 290, y: 384))
ctx.strokePath()

// `_`: the cursor, in the working color.
ctx.setStrokeColor(color(0x3DD6A0))
ctx.move(to: CGPoint(x: 540, y: 384))
ctx.addLine(to: CGPoint(x: 730, y: 384))
ctx.strokePath()

// A four-point sparkle, top right.
func sparkle(at c: CGPoint, radius r: CGFloat) {
    let path = CGMutablePath()
    let waist = r * 0.22
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y + waist))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + waist, y: c.y - waist))
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y - waist))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - waist, y: c.y + waist))
    ctx.addPath(path)
    ctx.setFillColor(color(0xF2B45A))
    ctx.fillPath()
}
sparkle(at: CGPoint(x: 700, y: 700), radius: 92)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
