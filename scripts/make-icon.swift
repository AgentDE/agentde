// Draws AgentDE's app icon: Termi, the mascot (a terminal window with a face), centered on a dark tile.
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

// Termi in his working green, from the mascot's 200-unit drawing (y down). His outline (x 22–178, y 38–174)
// is centered on the tile.
let scale: CGFloat = 4.3
let center = CGPoint(x: 100, y: 106)
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ fill: UInt32) {
    let rect = CGRect(x: 512 + (x - center.x) * scale, y: 512 - (y + h - center.y) * scale, width: w * scale, height: h * scale)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r * scale, cornerHeight: r * scale, transform: nil))
    ctx.setFillColor(color(fill))
    ctx.fillPath()
}
let shade: UInt32 = 0x127256, body: UInt32 = 0x1D9E75, glow: UInt32 = 0x6FD9B2, screen: UInt32 = 0x0E1114, white: UInt32 = 0xFFFFFF
box(68, 146, 20, 28, 4, shade)      // legs
box(112, 146, 20, 28, 4, shade)
box(22, 100, 18, 30, 6, shade)      // arms
box(160, 100, 18, 30, 6, shade)
box(36, 44, 128, 110, 14, shade)    // body's shadow
box(36, 38, 128, 110, 14, body)     // body
box(48, 47, 14, 12, 3, white)       // the window's three dots
box(68, 47, 14, 12, 3, white)
box(88, 47, 14, 12, 3, white)
box(46, 66, 108, 74, 7, screen)     // the screen: his face
box(65, 90, 16, 20, 2, glow)        // eyes, each with a glint
box(68, 93, 5, 5, 0, white)
box(119, 90, 16, 20, 2, glow)
box(122, 93, 5, 5, 0, white)
box(82, 116, 6, 5, 0, glow)         // smile
box(88, 121, 24, 6, 1, glow)
box(112, 116, 6, 5, 0, glow)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
