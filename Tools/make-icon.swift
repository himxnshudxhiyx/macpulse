// Renders the MacPulse app icon at 1024pt. Run via `swift Tools/make-icon.swift <out.png>`;
// build.sh then slices it into an .icns.
import AppKit
import CoreGraphics
import Foundation

let size = 1024.0
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create bitmap context")
}

// Rounded-square plate with a deep blue-to-indigo gradient.
let inset = size * 0.06
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let plateePath = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.235, cornerHeight: plate.width * 0.235, transform: nil)
context.saveGState()
context.addPath(plateePath)
context.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [CGColor(red: 0.09, green: 0.13, blue: 0.29, alpha: 1),
                                   CGColor(red: 0.16, green: 0.22, blue: 0.52, alpha: 1),
                                   CGColor(red: 0.10, green: 0.36, blue: 0.62, alpha: 1)] as CFArray,
                          locations: [0, 0.55, 1])!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY),
                           options: [])

// Gauge arc: the "how loaded is this machine" motif.
let center = CGPoint(x: size / 2, y: size / 2 - size * 0.02)
let radius = size * 0.29
context.setLineCap(.round)

context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
context.setLineWidth(size * 0.075)
context.addArc(center: center, radius: radius, startAngle: .pi * 1.18, endAngle: .pi * -0.18, clockwise: true)
context.strokePath()

// The filled portion sweeps through green → yellow, so the icon reads as a meter.
context.saveGState()
context.setLineWidth(size * 0.075)
context.addArc(center: center, radius: radius, startAngle: .pi * 1.18, endAngle: .pi * 0.42, clockwise: true)
context.replacePathWithStrokedPath()
context.clip()
let arcGradient = CGGradient(colorsSpace: colorSpace,
                             colors: [CGColor(red: 0.20, green: 0.85, blue: 0.55, alpha: 1),
                                      CGColor(red: 0.55, green: 0.90, blue: 0.35, alpha: 1),
                                      CGColor(red: 0.98, green: 0.82, blue: 0.25, alpha: 1)] as CFArray,
                             locations: [0, 0.6, 1])!
context.drawLinearGradient(arcGradient,
                           start: CGPoint(x: center.x - radius, y: center.y),
                           end: CGPoint(x: center.x + radius, y: center.y + radius),
                           options: [])
context.restoreGState()

// Heartbeat trace across the middle.
let pulse = CGMutablePath()
let baseline = center.y - size * 0.015
let left = center.x - size * 0.225
let width = size * 0.45
let points: [(CGFloat, CGFloat)] = [
    (0.00, 0.00), (0.24, 0.00), (0.34, 0.075), (0.45, -0.105),
    (0.57, 0.155), (0.69, -0.05), (0.79, 0.00), (1.00, 0.00),
]
for (index, point) in points.enumerated() {
    let location = CGPoint(x: left + width * point.0, y: baseline + size * point.1)
    if index == 0 { pulse.move(to: location) } else { pulse.addLine(to: location) }
}
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
context.setLineWidth(size * 0.038)
context.setLineJoin(.round)
context.addPath(pulse)
context.strokePath()

context.restoreGState()

// Subtle top highlight so the plate has some depth.
context.saveGState()
context.addPath(plateePath)
context.clip()
let sheen = CGGradient(colorsSpace: colorSpace,
                       colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                                CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                       locations: [0, 1])!
context.drawLinearGradient(sheen,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.minX, y: plate.midY + plate.height * 0.1),
                           options: [])
context.restoreGState()

guard let image = context.makeImage() else { fatalError("Could not render icon") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
try data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
