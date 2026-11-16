// Builds the app iconset from a rendered master image.
//
// Usage: swift tools/make-icon.swift <master.(png|jpg)> <iconset-dir>
//
// The master is expected to be a rendered plate on a light background (image
// generators cannot emit alpha). This tool finds the plate, crops to it, and
// masks the Jorvik plate geometry: full bleed, corner radius 0.22 of the
// side (reference_jorvik_icon_plate). The iconset sizes macOS wants are all
// written from that one masked square; `iconutil -c icns` does the rest.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write("usage: make-icon <master> <iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let masterPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

func loadCG(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return img
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("cannot create \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("cannot write \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

let master = loadCG(masterPath)
let w = master.width
let h = master.height
let side = min(w, h)

// Center square crop first (the generator may return a non-square canvas).
let square = master.cropping(to: CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side))!

// Luminance scan to find the dark plate bounds: draw an 8-bit grayscale
// downsample, threshold, take the bounding box of dark pixels.
let sampleSize = 256
let sampleScale = Double(sampleSize) / Double(side)
var sample = [UInt8](repeating: 0, count: sampleSize * sampleSize)
let gray = CGContext(data: &sample, width: sampleSize, height: sampleSize,
                     bitsPerComponent: 8, bytesPerRow: sampleSize,
                     space: CGColorSpaceCreateDeviceGray(),
                     bitmapInfo: CGImageAlphaInfo.none.rawValue)!
gray.interpolationQuality = .medium
gray.draw(square, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

var minX = sampleSize, minY = sampleSize, maxX = 0, maxY = 0
for y in 0..<sampleSize {
    for x in 0..<sampleSize where sample[y * sampleSize + x] < 128 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write("plate not found in master (no dark pixels)\n".data(using: .utf8)!)
    exit(1)
}

// Convert to full-resolution coordinates and inset slightly so the baked
// shadow edge falls outside the crop.
let inset = Int(Double(side) * 0.01)
let px0 = max(0, Int(Double(minX) / sampleScale) + inset)
let py0 = max(0, Int(Double(minY) / sampleScale) + inset)
let px1 = min(side, Int(Double(maxX + 1) / sampleScale) - inset)
let py1 = min(side, Int(Double(maxY + 1) / sampleScale) - inset)
let plateSide = min(px1 - px0, py1 - py0)

let cropped = square.cropping(to: CGRect(x: px0, y: py0, width: plateSide, height: plateSide))!

// Render at 1024 with the rounded-rect alpha mask.
let out = 1024
let radius = Double(out) * 0.22
let ctx = CGContext(data: nil, width: out, height: out,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let plate = CGRect(x: 0, y: 0, width: out, height: out)
ctx.beginPath()
ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.draw(cropped, in: plate)
let masked = ctx.makeImage()!

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Every iconset size, scaled from the one masked master.
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]
for (base, scale) in sizes {
    let px = base * scale
    let small = CGContext(data: nil, width: px, height: px,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(masked, in: CGRect(x: 0, y: 0, width: px, height: px))
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    writePNG(small.makeImage()!, to: "\(outDir)/\(name)")
}
print("iconset written to \(outDir) (plate \(plateSide)x\(plateSide) at \(px0),\(py0))")
