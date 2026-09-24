// Tests/AgentVMKitTests/GuestWallpaperTests.swift
//
// The wallpaper drawn on the Mac: a PNG at the box display's size, and a long name still fits.
// Setting it needs a guest desktop session; the extended shell tier covers that.

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AgentVMKit

@Suite struct GuestWallpaperTests {
    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The gray of one pixel (0...255), counted from the top left.
    private func gray(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(pixel[0])
    }

    @Test func drawsAtDisplaySize() throws {
        let data = try GuestWallpaper.png(title: "dev", lines: ["agent-vm image", "macOS 27.0 (26A428)"])
        #expect(data.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        let image = try decode(data)
        #expect(image.width == MacMachineSpec.displayWidth)
        #expect(image.height == MacMachineSpec.displayHeight)
        // Dark gray in the corner, light text somewhere on the middle row band.
        #expect(try gray(image, x: 0, y: 0) < 60)
        let middle = image.height / 2
        var brightest = 0
        for x in stride(from: 0, to: image.width, by: 2) {
            for y in (middle - 60)...(middle + 10) where y % 4 == 0 {
                brightest = max(brightest, try gray(image, x: x, y: y))
            }
        }
        #expect(brightest > 180)
    }

    @Test func longTitleStaysOnScreen() throws {
        let image = try decode(try GuestWallpaper.png(title: String(repeating: "w", count: 63), lines: []))
        // The longest name allowed, of the widest letter, shrunk to fit: the edges stay background.
        for y in stride(from: 0, to: image.height, by: 8) {
            #expect(try gray(image, x: 2, y: y) < 60)
            #expect(try gray(image, x: image.width - 3, y: y) < 60)
        }
    }

    @Test func featureIsAnnounced() {
        #expect(GuestFeature.all.contains(GuestFeature.wallpaper))
    }
}
