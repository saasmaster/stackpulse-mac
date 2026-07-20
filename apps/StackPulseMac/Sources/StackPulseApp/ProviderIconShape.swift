import CoreGraphics
import Foundation
import SwiftUI

/// A SwiftUI `Shape` built from an SVG path `d` string, scaled to fit its frame and centered.
///
/// Normalization is by the artwork's **true bounding box**, not the declared `viewBox`. Vendor SVGs
/// disagree about padding: Claude, Codex and Cursor sit roughly 10% inside a 100×100 box, while
/// Devin and Grok run edge-to-edge in a tightly-cropped one. Fitting the declared box would make the
/// padded marks render visibly smaller than their neighbours in the same row. Fitting the real path
/// bounds gives every mark the same optical weight, and a single shared `inset` then adds the
/// breathing room uniformly, so the padding is ours and consistent rather than each vendor's.
struct ProviderIconShape: Shape {
    let pathData: String
    /// Fraction of the frame kept as margin on every side.
    var inset: CGFloat = 0.04

    func path(in rect: CGRect) -> Path {
        guard let normalized = ProviderIconShape.normalized(pathData) else { return Path() }
        let target = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        guard target.width > 0, target.height > 0 else { return Path() }
        let size = normalized.size
        let scale = min(target.width / size.width, target.height / size.height)
        // `normalized.path` already has its bounding box origin at (0, 0), so centering is just the
        // leftover slack in each axis.
        let dx = target.minX + (target.width - size.width * scale) / 2
        let dy = target.minY + (target.height - size.height * scale) / 2
        return normalized.path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: dx, y: dy))
    }

    // MARK: - Parse cache

    /// A parsed mark, pre-translated so its bounding box starts at the origin, plus that box's size.
    /// Storing it this way keeps `path(in:)` down to two affine transforms — these marks are drawn
    /// in list rows that re-render on every usage refresh, and re-parsing a 5 KB `d` string per row
    /// per frame is exactly the kind of cost that shows up as menu-bar jank.
    private struct Normalized {
        let path: Path
        let size: CGSize
    }

    /// Keyed by the `d` string itself: mark data is immutable and there are ten of them, so the
    /// cache is bounded by construction and needs no eviction. Guarded by a plain lock rather than
    /// an actor or `@MainActor` so `path(in:)` stays synchronous and callable off the main actor.
    private nonisolated(unsafe) static var cache: [String: Normalized?] = [:]
    private static let cacheLock = NSLock()

    private static func normalized(_ d: String) -> Normalized? {
        cacheLock.lock()
        if let hit = cache[d] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let raw = SVGPath.parse(d)
        let bounds = raw.cgPath.boundingBoxOfPath
        let value: Normalized?
        if bounds.isNull || bounds.isInfinite || !bounds.width.isFinite || !bounds.height.isFinite
            || bounds.width <= 0 || bounds.height <= 0 {
            value = nil
        } else {
            value = Normalized(
                path: raw.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)),
                size: bounds.size
            )
        }

        cacheLock.lock()
        cache[d] = value
        cacheLock.unlock()
        return value
    }

    // MARK: - Self-test

    /// Hand-computed geometry fixtures, one per parser feature that can fail *quietly*.
    ///
    /// The mark loop below only proves a `d` string yields *some* non-degenerate shape. That is a
    /// blind spot with a shape we have paid for before (a substring model match silently mispriced
    /// Opus 4.8): a mis-reflected `S`/`T`, a relative `l`/`c` applied as absolute, or a dropped
    /// implicit command repetition all still produce a non-empty path with a positive bounding box.
    /// Only exact bounds separate a correct parse from a plausible-looking wrong one.
    ///
    /// Every expected value here was derived from the Bézier at its extremum by hand — none of it
    /// was read back out of this parser, which is the whole point.
    private static let geometryFixtures: [(d: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
        // Relative lineto + closepath: a 10×10 square on the origin.
        ("M0 0 l10 0 l0 10 z", 0, 0, 10, 10),

        // Same diagonal written absolute and relative. Identical bounds, or `l` is being treated as
        // absolute — which draws a plausible line to the wrong place rather than failing.
        ("M10 10 L20 20", 10, 10, 10, 10),
        ("M10 10 l10 10", 10, 10, 10, 10),
        // The same pairing for a cubic, where an absolute-vs-relative slip is far less visible.
        ("M0 0 C10 0 10 10 20 10", 0, 0, 20, 10),
        ("M0 0 c10 0 10 10 20 10", 0, 0, 20, 10),

        // Smooth cubic. The `S`'s first control is the reflection of the previous C2 (10,10) about
        // the current point (10,0), i.e. (10,-10); each half then peaks at ±7.5. Drop the reflection
        // (use the current point instead) and the height collapses to 11.94 — still a fine-looking
        // curve, just not the vendor's.
        ("M0 0 C0 10 10 10 10 0 S20 -10 20 0", 0, -7.5, 20, 15),

        // Smooth quad. The `T`'s control is the reflection of (10,-20) about (20,0), i.e. (30,20),
        // so the second hump mirrors the first and the height is 20. Without the reflection the
        // control lands on the current point, the second hump flattens, and the height reads 10.
        ("M0 0 Q10 -20 20 0 T40 0", 0, -10, 40, 20),

        // Implicit command repetition: the second coordinate pair repeats the `L`. If it were
        // dropped the path would be the flat segment (0,0)→(5,0) — height 0, not 5.
        ("M0 0 L5 0 5 5", 0, 0, 5, 5),

        // No embedded mark uses `A`, so this fixture is the arc branch's only exercise — the branch
        // is kept because deleting it would make a future mark's arc silently vanish, and kept
        // *pinned* because unreached code rots. A radius-10 semicircle from (0,0) to (20,0) sweeping
        // positive bulges to
        // y = -10: width 20, height 10. Endpoint→center conversion is the easiest part of an SVG
        // parser to get subtly wrong, and an untested one would surface as a wrong shape the first
        // time a future mark ships an arc.
        ("M0 0 A10 10 0 0 1 20 0", 0, -10, 20, 10),
    ]

    /// Bounds come out of Core Graphics' numeric Bézier extremum solve on top of `cos`/`sin`, so
    /// exact equality isn't available. 0.05 is still ~60× tighter than the smallest regression
    /// above (dropping the `S` reflection moves the height by 3.06), so the slack buys robustness
    /// without blunting a single assertion.
    private static let geometryTolerance: CGFloat = 0.05

    /// Parses every embedded mark and asserts it yields a non-empty path with finite, non-degenerate
    /// bounds. Cheap insurance against a mark being pasted in truncated: a half-copied `d` string
    /// still parses, it just silently draws a sliver, which is far easier to catch here than by eye.
    /// The exact-geometry fixtures run first — they are what actually pins the parser; the mark loop
    /// is the smoke check on top.
    static func _selftest() -> Bool {
        for f in geometryFixtures {
            let b = SVGPath.parse(f.d).cgPath.boundingBoxOfPath
            guard !b.isNull, !b.isInfinite else { return false }
            guard abs(b.minX - f.x) <= geometryTolerance,
                  abs(b.minY - f.y) <= geometryTolerance,
                  abs(b.width - f.w) <= geometryTolerance,
                  abs(b.height - f.h) <= geometryTolerance
            else { return false }
        }

        for id in ProviderMarks.allMarkIDs {
            guard let d = ProviderMarks.mark(for: id) else { return false }
            let parsed = SVGPath.parse(d)
            if parsed.isEmpty { return false }
            let b = parsed.cgPath.boundingBoxOfPath
            guard !b.isNull, !b.isInfinite,
                  b.origin.x.isFinite, b.origin.y.isFinite,
                  b.width.isFinite, b.height.isFinite,
                  b.width > 0, b.height > 0
            else { return false }
            if normalized(d) == nil { return false }
        }
        // Gemini must stay vector-less so the SF Symbol fallback path keeps being exercised.
        return ProviderMarks.mark(for: "gemini") == nil
    }
}

// MARK: - SVG path parsing

/// Minimal SVG path parser: `M m L l H h V v C c S s Q q T t A a Z z`, absolute and relative,
/// with implicit command repetition (`M x y x y …` continues as lineto), comma-or-whitespace
/// separators, sign-delimited numbers (`10-5` is two numbers) and scientific notation.
///
/// Arcs are supported even though none of the ten embedded marks currently use one — a future mark
/// pasted from a vendor's site is more likely to contain an `A` than any other command we'd be
/// missing, and a silently-dropped arc draws a wrong shape rather than failing loudly.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        let n = chars.count
        var i = 0

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var prevWasCubic = false
        var prevWasQuad = false
        var open = false

        func skipSeparators() {
            while i < n {
                switch chars[i] {
                case " ", ",", "\n", "\t", "\r": i += 1
                default: return
                }
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
            var sawDot = false
            var sawDigit = false
            while i < n {
                let c = chars[i]
                if c.isASCII && c.isNumber {
                    sawDigit = true
                    s.append(c); i += 1
                } else if c == "." && !sawDot {
                    sawDot = true
                    s.append(c); i += 1
                } else if (c == "e" || c == "E") && sawDigit {
                    // Only an exponent if digits actually follow, otherwise this letter is the next
                    // command and consuming it would swallow a drawing instruction.
                    var j = i + 1
                    if j < n, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    guard j < n, chars[j].isASCII, chars[j].isNumber else { break }
                    while i < j { s.append(chars[i]); i += 1 }
                } else {
                    break
                }
            }
            guard sawDigit, let value = Double(s), value.isFinite else { return nil }
            return CGFloat(value)
        }

        /// Arc flags are single characters and may be written unseparated (`…1 0 1 …` or `…101…`),
        /// so they can't go through `readNumber`, which would greedily eat all three.
        func readFlag() -> Bool? {
            skipSeparators()
            guard i < n else { return nil }
            switch chars[i] {
            case "0": i += 1; return false
            case "1": i += 1; return true
            default: return nil
            }
        }

        func readPoint(relative: Bool) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        func reflected() -> CGPoint {
            guard let lc = lastControl else { return current }
            return CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
        }

        /// Some marks begin a subpath with a drawing command after a `Z`; SwiftUI traps on adding a
        /// segment with no current point, so make sure one exists.
        func ensureOpen() {
            if !open {
                path.move(to: current)
                subpathStart = current
                open = true
            }
        }

        while i < n {
            skipSeparators()
            if i >= n { break }

            if chars[i].isLetter {
                lastCommand = chars[i]
                i += 1
            }

            let cmd = lastCommand
            var failed = false
            var isCubic = false
            var isQuad = false

            switch cmd {
            case "M", "m":
                if let p = readPoint(relative: cmd == "m") {
                    path.move(to: p)
                    current = p
                    subpathStart = p
                    open = true
                    // A moveto's extra coordinate pairs are linetos, per the SVG spec.
                    lastCommand = (cmd == "m") ? "l" : "L"
                } else { failed = true }

            case "L", "l":
                if let p = readPoint(relative: cmd == "l") {
                    ensureOpen()
                    path.addLine(to: p)
                    current = p
                } else { failed = true }

            case "H", "h":
                if let x = readNumber() {
                    let p = CGPoint(x: cmd == "h" ? current.x + x : x, y: current.y)
                    ensureOpen()
                    path.addLine(to: p)
                    current = p
                } else { failed = true }

            case "V", "v":
                if let y = readNumber() {
                    let p = CGPoint(x: current.x, y: cmd == "v" ? current.y + y : y)
                    ensureOpen()
                    path.addLine(to: p)
                    current = p
                } else { failed = true }

            case "C", "c":
                if let c1 = readPoint(relative: cmd == "c"),
                   let c2 = readPoint(relative: cmd == "c"),
                   let end = readPoint(relative: cmd == "c") {
                    ensureOpen()
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "S", "s":
                if let c2 = readPoint(relative: cmd == "s"),
                   let end = readPoint(relative: cmd == "s") {
                    let c1 = prevWasCubic ? reflected() : current
                    ensureOpen()
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "Q", "q":
                if let c = readPoint(relative: cmd == "q"),
                   let end = readPoint(relative: cmd == "q") {
                    ensureOpen()
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "T", "t":
                if let end = readPoint(relative: cmd == "t") {
                    let c = prevWasQuad ? reflected() : current
                    ensureOpen()
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "A", "a":
                if let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
                   let largeArc = readFlag(), let sweep = readFlag(),
                   let end = readPoint(relative: cmd == "a") {
                    ensureOpen()
                    appendArc(
                        to: &path, from: current, to: end,
                        rx: rx, ry: ry, rotationDegrees: rotation,
                        largeArc: largeArc, sweep: sweep
                    )
                    current = end
                } else { failed = true }

            case "Z", "z":
                if open { path.closeSubpath() }
                current = subpathStart
                open = false
                // Nothing is consumed by a closepath, so a stray number after it would spin this
                // loop forever. Force the next token to be a command letter.
                lastCommand = " "

            default:
                failed = true
            }

            if failed { break }
            prevWasCubic = isCubic
            prevWasQuad = isQuad
        }

        return path
    }

    /// Endpoint-parameterized arc → center parameterization → cubic segments (SVG appendix F.6).
    private static func appendArc(
        to path: inout Path,
        from p0: CGPoint,
        to p1: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if p0 == p1 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        // A zero radius degenerates to a straight line, per spec.
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale up radii that are too small to span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = den > 0 ? sign * sqrt(max(0, num / den)) : 0
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            let a = acos(max(-1, min(1, dot / len)))
            return (ux * vy - uy * vx < 0) ? -a : a
        }

        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // A cubic approximates at most a quarter turn before the error becomes visible.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var t = theta1
        for _ in 0..<segments {
            let t2 = t + step
            let cosT = cos(t), sinT = sin(t)
            let cosT2 = cos(t2), sinT2 = sin(t2)

            func point(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + rx * c * cosPhi - ry * s * sinPhi,
                    y: cy + rx * c * sinPhi + ry * s * cosPhi
                )
            }
            func derivative(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(
                    x: -rx * s * cosPhi - ry * c * sinPhi,
                    y: -rx * s * sinPhi + ry * c * cosPhi
                )
            }

            let start = point(cosT, sinT)
            let endPoint = point(cosT2, sinT2)
            let d1 = derivative(cosT, sinT)
            let d2 = derivative(cosT2, sinT2)
            path.addCurve(
                to: endPoint,
                control1: CGPoint(x: start.x + k * d1.x, y: start.y + k * d1.y),
                control2: CGPoint(x: endPoint.x - k * d2.x, y: endPoint.y - k * d2.y)
            )
            t = t2
        }
    }
}
