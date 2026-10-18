// Tests/AgentVMKitTests/GuestWallpaperTests.swift
//
// The wallpaper drawn on the Mac: a PNG at the box display's size, and a long name still fits.
// Setting it needs a guest desktop session; the extended shell tier covers that. And the box
// window's title and the shape of a view-only window; resizing the display needs a guest.

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
        let data = try GuestWallpaper.png(title: "dev", lines: ["AgentVM image", "macOS 27.0 (26A428)"])
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

@MainActor
struct BoxViewerTitleTests {
    @Test func theWindowTitleNamesTheProjectAndWhatIsShown() {
        #expect(BoxViewer.title(kind: "box", name: "work", interactive: true) == "AgentVM box - work")
        #expect(BoxViewer.title(kind: "box", name: "work", interactive: false) == "AgentVM box - work (view only)")
        #expect(BoxViewer.title(kind: "image", name: "dev", interactive: true) == "AgentVM image - dev")
    }
}

/// A view-only window takes the shape of the guest's display: the frame it gets.
@MainActor
struct BoxViewerShapeTests {
    /// A window whose content is `content`, under 68 points of title bar and the bar below it,
    /// with its top edge at 1000.
    private func window(_ content: NSSize) -> NSRect {
        return NSRect(x: 100, y: 1000 - content.height - 68, width: content.width, height: content.height + 68)
    }

    @Test func theWidthAndTheTopEdgeStay() throws {
        let frame = try #require(BoxViewer.frame(window(NSSize(width: 1400, height: 700)), content: NSSize(width: 1400, height: 700),
                                                 shapedLike: CGSize(width: 1280, height: 800), visible: nil))
        #expect(frame == NSRect(x: 100, y: 1000 - 875 - 68, width: 1400, height: 875 + 68))
    }

    @Test func aWindowTooTallForTheScreenGetsNarrower() throws {
        // 1400 wide at 16:10 needs 875 points, and the screen leaves 800 - 68 for the content.
        let frame = try #require(BoxViewer.frame(window(NSSize(width: 1400, height: 700)), content: NSSize(width: 1400, height: 700),
                                                 shapedLike: CGSize(width: 1280, height: 800), visible: NSRect(x: 0, y: 0, width: 1710, height: 800)))
        #expect(frame.size == NSSize(width: 1171, height: 800))
        #expect(frame.maxY == 1000)
        #expect(frame.minX == 100)
    }

    @Test func theBottomEdgeStaysOnTheScreen() throws {
        // 1400 by 875 under its top edge at 1000 would reach down to 57, below the Dock at 100.
        let frame = try #require(BoxViewer.frame(window(NSSize(width: 1400, height: 700)), content: NSSize(width: 1400, height: 700),
                                                 shapedLike: CGSize(width: 1280, height: 800), visible: NSRect(x: 0, y: 100, width: 1710, height: 1000)))
        #expect(frame == NSRect(x: 100, y: 100, width: 1400, height: 875 + 68))
    }

    @Test func theRightShapeIsLeftAlone() {
        #expect(BoxViewer.frame(window(NSSize(width: 1000, height: 625)), content: NSSize(width: 1000, height: 625),
                                shapedLike: CGSize(width: 1280, height: 800), visible: nil) == nil)
        // Less than a point off is the same shape.
        #expect(BoxViewer.frame(window(NSSize(width: 1001, height: 625.4)), content: NSSize(width: 1001, height: 625.4),
                                shapedLike: CGSize(width: 1280, height: 800), visible: nil) == nil)
    }

    @Test func noDisplaySizeChangesNothing() {
        #expect(BoxViewer.frame(window(NSSize(width: 1000, height: 625)), content: NSSize(width: 1000, height: 625),
                                shapedLike: .zero, visible: nil) == nil)
    }

    @Test func theDisplayStartsAtItsMachineSize() {
        #expect(BoxViewer.startSize == CGSize(width: MacMachineSpec.displayWidth, height: MacMachineSpec.displayHeight))
        #expect(BoxViewer.minimumSize.width <= BoxViewer.startSize.width && BoxViewer.minimumSize.height <= BoxViewer.startSize.height)
    }
}
