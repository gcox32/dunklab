#!/usr/bin/env swift
// Renders the app icon: the tab bar's basketball symbol, white on vane blue.
// Usage: swift Tools/make_icon.swift DunkLab/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import AppKit
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// Icons must be opaque: no alpha channel.
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Vane blue, #2457A8.
context.setFillColor(CGColor(srgbRed: 0x24 / 255, green: 0x57 / 255, blue: 0xA8 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
guard let symbol = NSImage(systemSymbolName: "basketball", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else {
    fatalError("basketball symbol not found")
}

NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let glyph = symbol.size
let rect = CGRect(
    x: (CGFloat(size) - glyph.width) / 2, y: (CGFloat(size) - glyph.height) / 2,
    width: glyph.width, height: glyph.height)
symbol.draw(in: rect)
NSGraphicsContext.current = nil

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(output.path)") }
print("Wrote \(output.path) (glyph \(Int(glyph.width))×\(Int(glyph.height)))")
