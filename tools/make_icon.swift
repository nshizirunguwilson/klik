#!/usr/bin/env swift
//
// Draws Klik's app icon and writes Resources/AppIcon.icns.
//
//   swift tools/make_icon.swift
//
// A single keycap, because that is what the app is. Deliberately plain: the
// icon has to stay readable at 16 points in a Finder list.

import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setShouldAntialias(true)

    // Rounded-square backdrop, matching the macOS app icon silhouette.
    let inset = size * 0.045
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = size * 0.222
    let platePath = CGPath(roundedRect: plate, cornerWidth: plateRadius,
                           cornerHeight: plateRadius, transform: nil)
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let backdrop = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1),
            CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        backdrop,
        start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
    context.restoreGState()

    // The keycap.
    let capSize = size * 0.54
    let capOrigin = (size - capSize) / 2
    let cap = CGRect(x: capOrigin, y: capOrigin - size * 0.015, width: capSize, height: capSize)
    let capRadius = capSize * 0.20

    // Soft drop shadow so the cap sits above the plate rather than on it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.018),
                      blur: size * 0.045,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
    context.addPath(CGPath(roundedRect: cap, cornerWidth: capRadius,
                           cornerHeight: capRadius, transform: nil))
    context.setFillColor(CGColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Top-lit face.
    context.saveGState()
    context.addPath(CGPath(roundedRect: cap, cornerWidth: capRadius,
                           cornerHeight: capRadius, transform: nil))
    context.clip()
    let face = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1),
            CGColor(red: 0.76, green: 0.78, blue: 0.81, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        face,
        start: CGPoint(x: 0, y: cap.maxY), end: CGPoint(x: 0, y: cap.minY), options: [])
    context.restoreGState()

    // "K", sized to the cap.
    let letterSize = capSize * 0.62
    let font = NSFont.systemFont(ofSize: letterSize, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1),
    ]
    let letter = NSAttributedString(string: "K", attributes: attributes)
    let letterBounds = letter.size()
    letter.draw(at: NSPoint(
        x: cap.midX - letterBounds.width / 2,
        y: cap.midY - letterBounds.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set of names iconutil expects.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in variants {
    let rep = draw(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()

if convert.terminationStatus == 0 {
    print("Wrote Resources/AppIcon.icns")
} else {
    print("iconutil failed (\(convert.terminationStatus))")
    exit(1)
}
