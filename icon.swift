#!/usr/bin/env swift
// Draws the app icon: the obsidian blob and its swarm, on a dark rounded-square tile.
// Run via ./makeicon.sh — writes one PNG at the size given on the command line.
import AppKit

let size = Double(CommandLine.arguments.dropFirst().first ?? "1024") ?? 1024
let out = CommandLine.arguments.dropFirst(2).first ?? "icon.png"
let s = size / 1024   // everything below is authored at 1024 and scaled

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icons sit in a rounded square with a ~10% margin.
let margin = 100 * s
let tile = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

ctx.saveGState()
squircle.addClip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 1).cgColor,
                             NSColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY),
                       end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

let cx = size / 2, cy = size / 2

// The cyan→violet halo, matching the recording state.
for (i, colour) in [NSColor(srgbRed: 0, green: 0.85, blue: 1, alpha: 1),
                    NSColor(srgbRed: 0.42, green: 0.36, blue: 1, alpha: 1)].enumerated() {
    // A radial fade to clear, not a filled disc with a shadow — a hard edge here reads
    // as a second object instead of light.
    ctx.saveGState()
    let dx = (i == 0 ? -120.0 : 120.0) * s
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [colour.withAlphaComponent(0.85).cgColor,
                                   colour.withAlphaComponent(0.38).cgColor,
                                   colour.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 0.42, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: cx + dx, y: cy), startRadius: 0,
                           endCenter: CGPoint(x: cx + dx, y: cy), endRadius: 320 * s,
                           options: [])
    ctx.restoreGState()
}

/// Core plus three satellites, in the same resting pose as the running app.
let blobs: [(Double, Double, Double)] = [
    (0, 0, 210), (-250, 95, 62), (215, 130, 52), (170, -175, 44),
]

// Black glass, lit from the upper left.
for (bx, by, r) in blobs {
    let rect = CGRect(x: cx + bx * s - r * s, y: cy + by * s - r * s, width: r * 2 * s, height: r * 2 * s)
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    let body = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.20, green: 0.21, blue: 0.25, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.02, green: 0.02, blue: 0.04, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(body,
                           startCenter: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY - rect.height * 0.26),
                           startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY),
                           endRadius: rect.width * 0.78, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

// The iridescent seam across the core — the one bright element.
let seam = CGRect(x: cx - 185 * s, y: cy - 9 * s, width: 370 * s, height: 18 * s)
ctx.saveGState()
ctx.addEllipse(in: seam)
ctx.clip()
let seamGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor.clear.cgColor,
                                   NSColor(srgbRed: 0, green: 0.85, blue: 1, alpha: 1).cgColor,
                                   NSColor.white.cgColor,
                                   NSColor(srgbRed: 0.42, green: 0.36, blue: 1, alpha: 1).cgColor,
                                   NSColor.clear.cgColor] as CFArray,
                          locations: [0, 0.2, 0.5, 0.8, 1])!
ctx.setShadow(offset: .zero, blur: 40 * s, color: NSColor(srgbRed: 0, green: 0.85, blue: 1, alpha: 0.9).cgColor)
ctx.drawLinearGradient(seamGrad, start: CGPoint(x: seam.minX, y: seam.midY),
                       end: CGPoint(x: seam.maxX, y: seam.midY), options: [])
ctx.restoreGState()

// Top gloss.
ctx.saveGState()
let gloss = CGRect(x: cx - 118 * s, y: cy + 62 * s, width: 236 * s, height: 92 * s)
ctx.addEllipse(in: gloss)
ctx.clip()
// Fades out well before the ellipse edge, so it reads as a highlight rather than a slab.
let glossGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                    NSColor.white.withAlphaComponent(0.05).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 0.45, 1])!
ctx.drawLinearGradient(glossGrad, start: CGPoint(x: gloss.midX, y: gloss.maxY),
                       end: CGPoint(x: gloss.midX, y: gloss.minY), options: [])
ctx.restoreGState()
ctx.restoreGState()

image.unlockFocus()

let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
