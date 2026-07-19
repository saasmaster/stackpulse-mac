import AppKit
import SwiftUI

// MARK: - Menu-bar strip

/// Renders the menu-bar readout — each provider's brand mark followed by its
/// reading(s) — into a single **template** `NSImage`.
///
/// Why an image rather than an attributed title: two percentages per provider
/// have to sit *stacked* on two tight lines to stay narrow enough for the menu
/// bar, and text attachments can't stack. Drawing a SwiftUI view through
/// `ImageRenderer` gives the same layout the cards use, and marking it a template
/// lets macOS tint it for light/dark and for the highlighted (clicked) state — so
/// the strip always matches its neighbours instead of carrying baked-in colours.
@MainActor
enum MenuBarStripRenderer {

    /// Last render, memoized on its input. The status item is refreshed on every
    /// snapshot write — several times per refresh — while the visible strip rarely
    /// changes; returning the same instance keeps `ImageRenderer` runs down to
    /// actual visual changes.
    private static var lastRender: (items: [SnapshotStore.MenuBarItem], image: NSImage?)?

    /// The strip for these items, or `nil` when there is nothing to show (the
    /// caller then falls back to the plain app glyph).
    static func image(for items: [SnapshotStore.MenuBarItem]) -> NSImage? {
        if let lastRender, lastRender.items == items { return lastRender.image }
        let image = render(items)
        lastRender = (items, image)
        return image
    }

    private static func render(_ items: [SnapshotStore.MenuBarItem]) -> NSImage? {
        guard !items.isEmpty else { return nil }
        let scale: CGFloat = 2
        let renderer = ImageRenderer(content: MenuBarStrip(items: items))
        renderer.scale = scale
        guard let rendered = renderer.cgImage else { return nil }

        // Trim to visible pixels: the glyph's normalization inset and the view's
        // anti-aliasing padding would otherwise ship as transparent margin,
        // widening the status item past its artwork. The menu bar already pads
        // every item, so baked-in margin reads as an oversized gap.
        let cg = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = accessibilityText(items)
        return image
    }

    /// "Claude session 41% left, weekly 34% left; Codex 93% left" — the strip is
    /// an image, so without this VoiceOver would read nothing at all.
    static func accessibilityText(_ items: [SnapshotStore.MenuBarItem]) -> String {
        items.map { item in
            let readings: String
            switch item.values.count {
            case 0: readings = ""
            case 1: readings = item.values[0]
            default:
                readings = "session \(item.values[0]), weekly \(item.values[1])"
            }
            return "\(item.displayName) \(readings)"
        }
        .joined(separator: "; ")
    }

    // MARK: Trimming

    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// Bounding box of pixels with non-zero alpha, in pixel coordinates with the
    /// origin at the top-left row (what `CGImage.cropping(to:)` expects), or `nil`
    /// for a fully transparent image.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

// MARK: - The strip view

/// Black-on-clear so the template tint takes over. One cell per provider: the
/// brand mark, then either a single large number or two tight stacked lines.
private struct MenuBarStrip: View {
    let items: [SnapshotStore.MenuBarItem]

    /// Glyph box, sized to fill the strip's height so a mark reads at the same
    /// scale as the two-line block beside it rather than floating small.
    private static let glyphSide: CGFloat = 15

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    glyph(item)
                    values(item.values)
                }
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }

    /// One reading renders as a single readable number; two stack on two tight
    /// lines — far narrower than side by side, and read positionally (session on
    /// top, weekly below), which is why the cards spell the labels out and this
    /// doesn't.
    @ViewBuilder
    private func values(_ values: [String]) -> some View {
        if values.count <= 1 {
            Text(values.first ?? "")
                .font(.system(size: 12, weight: .bold))
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(Array(values.prefix(2).enumerated()), id: \.offset) { _, value in
                    Text(value)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .fixedSize()
        }
    }

    /// The provider's own brand mark, or an SF Symbol when we have no vector for
    /// it — never a letter code, which at this size was misread ("Cl" as "CI").
    @ViewBuilder
    private func glyph(_ item: SnapshotStore.MenuBarItem) -> some View {
        if let mark = ProviderMarks.mark(for: item.id) {
            ProviderIconShape(pathData: mark, inset: 0.04)
                .fill(Color.black)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
        } else {
            Image(systemName: item.symbolName)
                .font(.system(size: Self.glyphSide - 3, weight: .semibold))
                .frame(width: Self.glyphSide, height: Self.glyphSide)
        }
    }
}
