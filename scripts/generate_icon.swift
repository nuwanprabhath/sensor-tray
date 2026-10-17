#!/usr/bin/env swift
// Generates AppIcon.iconset (all sizes) from drawn vector shapes — no external
// image assets needed. Run via generate_icon.sh, which also builds the .icns.
import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

struct Spec { let name: String; let size: CGFloat }
let specs: [Spec] = [
    Spec(name: "icon_16x16", size: 16),
    Spec(name: "icon_16x16@2x", size: 32),
    Spec(name: "icon_32x32", size: 32),
    Spec(name: "icon_32x32@2x", size: 64),
    Spec(name: "icon_128x128", size: 128),
    Spec(name: "icon_128x128@2x", size: 256),
    Spec(name: "icon_256x256", size: 256),
    Spec(name: "icon_256x256@2x", size: 512),
    Spec(name: "icon_512x512", size: 512),
    Spec(name: "icon_512x512@2x", size: 1024),
]

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225
    let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Background: night-sky navy to deep teal.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [color(0.10, 0.13, 0.26), color(0.04, 0.33, 0.42)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    }
    ctx.restoreGState()

    // Thermometer: white tube + bulb, warm fill rising from the bulb.
    let tubeWidth = size * 0.15
    let tubeX = size * 0.30
    let bulbRadius = size * 0.13
    let bulbCenter = CGPoint(x: tubeX + tubeWidth / 2, y: size * 0.30)
    let tubeRect = CGRect(x: tubeX, y: bulbCenter.y, width: tubeWidth, height: size * 0.50)

    ctx.setFillColor(color(1, 1, 1, 0.96))
    ctx.addPath(CGPath(roundedRect: tubeRect, cornerWidth: tubeWidth / 2, cornerHeight: tubeWidth / 2, transform: nil))
    ctx.addEllipse(in: CGRect(x: bulbCenter.x - bulbRadius, y: bulbCenter.y - bulbRadius, width: bulbRadius * 2, height: bulbRadius * 2))
    ctx.fillPath()

    let warm = color(0.98, 0.45, 0.20)
    let inset = size * 0.035
    let fillWidth = tubeWidth - inset * 2
    let fillRect = CGRect(x: tubeX + inset, y: bulbCenter.y, width: fillWidth, height: size * 0.30)
    ctx.setFillColor(warm)
    ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: fillWidth / 2, cornerHeight: fillWidth / 2, transform: nil))
    let innerBulb = bulbRadius - inset
    ctx.addEllipse(in: CGRect(x: bulbCenter.x - innerBulb, y: bulbCenter.y - innerBulb, width: innerBulb * 2, height: innerBulb * 2))
    ctx.fillPath()

    // Tick marks on the tube's right side.
    ctx.setStrokeColor(color(1, 1, 1, 0.7))
    ctx.setLineWidth(max(1, size * 0.012))
    ctx.setLineCap(.round)
    for i in 0..<4 {
        let y = tubeRect.minY + size * (0.16 + CGFloat(i) * 0.085)
        ctx.move(to: CGPoint(x: tubeRect.maxX + size * 0.03, y: y))
        ctx.addLine(to: CGPoint(x: tubeRect.maxX + size * (i % 2 == 0 ? 0.09 : 0.06), y: y))
    }
    ctx.strokePath()

    // Humidity droplet on the right: point up, round bottom.
    let dropCenter = CGPoint(x: size * 0.70, y: size * 0.40)
    let dropRadius = size * 0.13
    let tip = CGPoint(x: dropCenter.x, y: dropCenter.y + dropRadius * 2.1)
    let drop = CGMutablePath()
    drop.move(to: tip)
    drop.addCurve(to: CGPoint(x: dropCenter.x + dropRadius, y: dropCenter.y),
                  control1: CGPoint(x: dropCenter.x + dropRadius * 0.25, y: tip.y - dropRadius * 0.6),
                  control2: CGPoint(x: dropCenter.x + dropRadius, y: dropCenter.y + dropRadius * 0.7))
    drop.addArc(center: dropCenter, radius: dropRadius, startAngle: 0, endAngle: .pi, clockwise: true)
    drop.addCurve(to: tip,
                  control1: CGPoint(x: dropCenter.x - dropRadius, y: dropCenter.y + dropRadius * 0.7),
                  control2: CGPoint(x: dropCenter.x - dropRadius * 0.25, y: tip.y - dropRadius * 0.6))
    drop.closeSubpath()

    ctx.saveGState()
    ctx.addPath(drop)
    ctx.clip()
    let dropColors = [color(0.55, 0.92, 0.98), color(0.20, 0.62, 0.95)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: dropColors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: tip, end: CGPoint(x: dropCenter.x, y: dropCenter.y - dropRadius), options: [])
    }
    ctx.restoreGState()

    // Highlight on the droplet.
    ctx.setStrokeColor(color(1, 1, 1, 0.75))
    ctx.setLineWidth(max(1, size * 0.018))
    ctx.addArc(center: dropCenter, radius: dropRadius * 0.6, startAngle: .pi * 1.05, endAngle: .pi * 1.35, clockwise: false)
    ctx.strokePath()

    image.unlockFocus()
    return image
}

for spec in specs {
    let image = drawIcon(size: spec.size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to render \(spec.name)\n".data(using: .utf8)!)
        continue
    }
    let path = (outputDir as NSString).appendingPathComponent("\(spec.name).png")
    try? png.write(to: URL(fileURLWithPath: path))
}
