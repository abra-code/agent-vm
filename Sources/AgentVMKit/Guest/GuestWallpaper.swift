// Sources/AgentVMKit/Guest/GuestWallpaper.swift
//
// A plain wallpaper that names the box or image on screen, so a window on a box (box view)
// says which one it shows. agent-vm draws it on the Mac: dark gray, the name large in the
// middle, a line or two of detail under it, at the box display's size. agent-vm-guest
// `wallpaper` sets it in the guest (the other half of GuestWallpaper, in AgentVMGuestKit).

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension GuestWallpaper {
    // MARK: - Drawing (on the Mac)

    /// A PNG of `title` over `lines`, centered on dark gray, `width` by `height` pixels. A
    /// title too wide for the screen is drawn smaller.
    static func png(title: String, lines: [String], width: Int = MacMachineSpec.displayWidth,
                    height: Int = MacMachineSpec.displayHeight) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentVMError.system(operation: "draw the wallpaper", code: ENOMEM)
        }
        context.setFillColor(gray: 0.18, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let maximumWidth = CGFloat(width) * 0.9
        var titleSize: CGFloat = 72
        var titleLine = line(title, font: .emphasizedSystem, size: titleSize, gray: 0.92)
        while titleSize > 16 && lineWidth(titleLine) > maximumWidth {
            titleSize -= 4
            titleLine = line(title, font: .emphasizedSystem, size: titleSize, gray: 0.92)
        }
        let rows = [titleLine] + lines.enumerated().map { index, text in
            line(text, font: .system, size: index == 0 ? 22 : 18, gray: 0.60)
        }
        let gap: CGFloat = 14
        let heights = rows.map(lineHeight)
        let total = heights.reduce(0, +) + gap * CGFloat(rows.count - 1)
        // Core Graphics counts y up from the bottom; start at the top of the centered block.
        var top = (CGFloat(height) + total) / 2
        for (row, rowHeight) in zip(rows, heights) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let rowWidth = CGFloat(CTLineGetTypographicBounds(row, &ascent, &descent, nil))
            context.textPosition = CGPoint(x: (CGFloat(width) - rowWidth) / 2, y: top - ascent)
            CTLineDraw(row, context)
            top -= rowHeight + gap
        }

        guard let image = context.makeImage() else {
            throw AgentVMError.system(operation: "draw the wallpaper", code: ENOMEM)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentVMError.system(operation: "encode the wallpaper", code: EINVAL)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentVMError.system(operation: "encode the wallpaper", code: EINVAL)
        }
        return data as Data
    }

    /// The wallpaper of a box: its name, then what it was cloned from.
    public static func png(for box: BoxRecord) throws -> Data {
        return try png(title: box.name, lines: ["AgentVM box", "image \(box.image)  -  \(box.systemDescription)"])
    }

    /// The wallpaper of an image, which its boxes show until they set their own.
    public static func png(for image: ImageRecord) throws -> Data {
        return try png(title: image.name, lines: ["AgentVM image", image.systemDescription])
    }

    private static func line(_ text: String, font: CTFontUIFontType, size: CGFloat, gray: CGFloat) -> CTLine {
        // The system UI fonts always exist; Helvetica stands in should one ever be missing.
        let face = CTFontCreateUIFontForLanguage(font, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): face,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func lineWidth(_ line: CTLine) -> CGFloat {
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func lineHeight(_ line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        return ascent + descent
    }
}
