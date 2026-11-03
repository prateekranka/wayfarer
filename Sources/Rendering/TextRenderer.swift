import CoreGraphics
import CoreImage
import CoreText
import Foundation
import MontageCore
import UIKit

/// One line of text, drawn once, and how it moves on screen.
struct TextLayer: @unchecked Sendable {
    /// The drawn line, with its bottom-left corner at the origin.
    let image: CIImage
    let cue: TextCue
    /// Where the center of the line sits, in Core Image's bottom-left space.
    let center: CGPoint
    let entrance: TextLook.Entrance
    let exit: TextLook.Exit
    /// The right edge of each character in the image, for the typewriter.
    let characterEdges: [CGFloat]
}

/// Draws titles with Core Text. Lines are drawn once per edit, so each frame
/// only moves, scales, and fades them.
enum TextRenderer {
    /// Lines never take more than this share of the frame's width.
    private static let widest = 0.86
    private static let subtitleScale = 0.5
    /// Subtitles never get smaller than this share of the frame's width.
    private static let smallestSubtitle = 0.036

    static func layers(cues: [TextCue], look: TextLook, placement: TextLook.Placement,
                       renderSize: CGSize) -> [TextLayer] {
        let span = TextPlanner.span(of: placement)
        let hasSubtitle = cues.contains { $0.role == .subtitle }
        let drawn = cues.compactMap { cue -> (TextCue, CIImage, [CGFloat])? in
            let size = renderSize.width * (cue.role == .title ? look.size : max(look.size * subtitleScale, smallestSubtitle))
            guard let line = draw(cue.text, look: look, role: cue.role, size: size, maxWidth: renderSize.width * widest) else { return nil }
            return (cue, line.image, line.edges)
        }
        // Stack the title over the subtitle, centered in the placement's band.
        let gap = renderSize.width * look.size * 0.18
        let total = drawn.reduce(0) { $0 + $1.1.extent.height } + (hasSubtitle && drawn.count > 1 ? gap : 0)
        let middle = renderSize.height * (1 - (span.lowerBound + span.upperBound) / 2)
        var top = middle + total / 2
        return drawn.map { cue, image, edges in
            let center = CGPoint(x: renderSize.width / 2, y: top - image.extent.height / 2)
            top -= image.extent.height + gap
            return TextLayer(image: image, cue: cue, center: center, entrance: look.entrance, exit: look.exit,
                             characterEdges: edges)
        }
    }

    private static func draw(_ text: String, look: TextLook, role: TextCue.Role, size: CGFloat,
                             maxWidth: CGFloat) -> (image: CIImage, edges: [CGFloat])? {
        let string = look.uppercase ? text.uppercased() : text
        var fontSize = max(8, size)
        var line = makeLine(string, look: look, role: role, size: fontSize)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        if width > maxWidth {
            fontSize *= maxWidth / width
            line = makeLine(string, look: look, role: role, size: fontSize)
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        // Room for the soft shadow that keeps text readable on bright shots.
        let pad = ceil(fontSize * 0.9)
        let pixelWidth = Int(ceil(lineWidth + pad * 2)), pixelHeight = Int(ceil(ascent + descent + pad * 2))
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A faint dark glow behind the whole line, with soft edges. Shadows
        // follow the letters, so thin type gets little of them; this does not.
        // Only the box's blurred shadow is drawn: the box itself sits far off
        // the image, so there is no hard edge.
        let away = CGFloat(pixelWidth + pixelHeight) * 4
        context.saveGState()
        context.setShadow(offset: CGSize(width: -away, height: 0), blur: pad * 1.1, color: CGColor(gray: 0, alpha: 0.4))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: pad + away, y: pad, width: lineWidth, height: ascent + descent).insetBy(dx: pad * 0.1, dy: 0))
        context.restoreGState()
        // A wide soft shadow, then a tight one, keep white text readable on
        // bright shots. White drawn over white does not change the letters.
        context.textPosition = CGPoint(x: pad, y: pad + descent)
        context.setShadow(offset: .zero, blur: fontSize * 0.55, color: CGColor(gray: 0, alpha: 0.75))
        CTLineDraw(line, context)
        context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.03), blur: fontSize * 0.1,
                          color: CGColor(gray: 0, alpha: 0.6))
        context.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        var edges: [CGFloat] = []
        var offset = 0
        for character in string {
            offset += character.utf16.count
            edges.append(pad + CTLineGetOffsetForStringIndex(line, offset, nil))
        }
        return (CIImage(cgImage: image), edges)
    }

    private static func makeLine(_ text: String, look: TextLook, role: TextCue.Role, size: CGFloat) -> CTLine {
        let font = font(look, role: role, size: size)
        let tracking = (look.tracking + (role == .subtitle ? 0.08 : 0)) * size
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .kern: tracking, .foregroundColor: UIColor.white.cgColor
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func font(_ look: TextLook, role: TextCue.Role, size: CGFloat) -> UIFont {
        let weights: [TextLook.Weight: UIFont.Weight] = [
            .light: .light, .regular: .regular, .medium: .medium, .semibold: .semibold,
            .bold: .bold, .heavy: .heavy, .black: .black
        ]
        // Subtitles are lighter, so the title leads.
        let weight = role == .title ? weights[look.weight] ?? .regular : look.weight == .light ? .light : .regular
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let design: UIFontDescriptor.SystemDesign? = switch look.design {
        case .sans: nil
        case .serif: .serif
        case .rounded: .rounded
        case .mono: .monospaced
        }
        guard let design, let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
