#!/usr/bin/env swift
import AppKit

private enum Layout {
    static let size = CGSize(width: 920, height: 520)
    static let appPanel = CGRect(x: 128, y: 148, width: 214, height: 214)
    static let chevron = CGRect(x: 433, y: 216, width: 54, height: 78)
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render-dmg-background.swift <output.png>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let image = NSImage(size: Layout.size)
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("error: could not create graphics context\n", stderr)
    exit(1)
}

context.saveGState()
context.translateBy(x: 0, y: Layout.size.height)
context.scaleBy(x: 1, y: -1)

NSColor(srgbRed: 0.955, green: 0.960, blue: 0.980, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: Layout.size)).fill()

let panelShadow = NSShadow()
panelShadow.shadowColor = NSColor.black.withAlphaComponent(0.07)
panelShadow.shadowBlurRadius = 12
panelShadow.shadowOffset = NSSize(width: 0, height: -6)
panelShadow.set()

let panelPath = NSBezierPath(roundedRect: Layout.appPanel, xRadius: 22, yRadius: 22)
NSColor(srgbRed: 0.865, green: 0.875, blue: 0.905, alpha: 1).setFill()
panelPath.fill()

context.setShadow(offset: .zero, blur: 0, color: nil)
NSColor.white.withAlphaComponent(0.62).setStroke()
panelPath.lineWidth = 3
panelPath.stroke()

let chevronPath = NSBezierPath()
chevronPath.move(to: CGPoint(x: Layout.chevron.minX + Layout.chevron.width * 0.28,
                             y: Layout.chevron.minY + Layout.chevron.height * 0.18))
chevronPath.line(to: CGPoint(x: Layout.chevron.minX + Layout.chevron.width * 0.72,
                             y: Layout.chevron.midY))
chevronPath.line(to: CGPoint(x: Layout.chevron.minX + Layout.chevron.width * 0.28,
                             y: Layout.chevron.minY + Layout.chevron.height * 0.82))
chevronPath.lineWidth = 12
chevronPath.lineCapStyle = .round
chevronPath.lineJoinStyle = .round
NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1).setStroke()
chevronPath.stroke()

context.restoreGState()
image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("error: could not encode PNG\n", stderr)
    exit(1)
}

try png.write(to: outputURL)
