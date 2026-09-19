#!/usr/bin/env swift
// Renders the app icon (a rounded gradient tile with an SF Symbol) into an
// .icns. Usage: swift scripts/make-icon.swift Packaging/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mss-icon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.70, alpha: 1)])!
        .draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .medium).applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = symbol.size
        let scale = min((rect.width * 0.62) / sz.width, (rect.height * 0.62) / sz.height)
        let w = sz.width * scale, h = sz.height * scale
        symbol.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    return image
}

for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = size * scale
    let img = render(size: px)
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try png.write(to: iconset.appendingPathComponent(name))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed (\(p.terminationStatus))")
exit(p.terminationStatus)
