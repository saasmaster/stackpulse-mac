import SwiftUI

// MARK: - Liquid Glass design system
//
// A hand-crafted Liquid Glass material (the CLT SDK here is macOS 15.2, so the
// native `.glassEffect` API from macOS 26 isn't available to compile against).
// It layers, back to front:
//   1. a frosted base material (opaque fallback under Reduce Transparency),
//   2. a diagonal refraction sheen (plus-lighter, for the wet "lens" pop),
//   3. an optional status tint wash,
//   4. a rim-light stroke (bright top edge fading down — specular highlight),
//   5. layered depth shadows + an optional colored glow.
//
// Everything is Reduce-Transparency and Reduce-Motion aware.

/// Tunable feel of a glass surface.
enum GlassProminence {
    case low       // rows, chips
    case regular   // cards, popover sections
    case elevated  // active / focused / floating panels
}

struct LiquidGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var prominence: GlassProminence = .regular
    /// Optional accent — tints the wash and colors the glow (status / selection).
    var tint: Color? = nil
    var padding: CGFloat? = 14

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(glass)
    }

    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            // 1. Frosted base (or solid under Reduce Transparency).
            if reduceTransparency {
                shape.fill(scheme == .dark ? Color(white: 0.16) : Color(white: 0.98))
            } else {
                shape.fill(baseMaterial)
            }
            // 2. Refraction sheen — a diagonal light streak across the glass.
            if !reduceTransparency {
                shape.fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [.white.opacity(0.14), .clear, .white.opacity(0.03)]
                            : [.white.opacity(0.60), .clear, .white.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)
            }
            // 3. Status tint wash.
            if let tint {
                shape.fill(tint.opacity(scheme == .dark ? 0.22 : 0.16))
            }
            // 4. Rim light — bright at the top, fading down.
            shape.strokeBorder(
                LinearGradient(
                    colors: rimColors,
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .compositingGroup()
        .shadow(color: .black.opacity(ambientOpacity), radius: ambientRadius, y: ambientY)
        .shadow(color: glowColor, radius: glowRadius, y: 1)
    }

    private var baseMaterial: Material {
        switch prominence {
        case .low: return .ultraThinMaterial
        case .regular: return .thinMaterial
        case .elevated: return .regularMaterial
        }
    }

    private var rimColors: [Color] {
        if scheme == .dark {
            return [.white.opacity(0.55), .white.opacity(0.06)]
        }
        return [.white.opacity(0.95), .white.opacity(0.22)]
    }

    private var ambientOpacity: Double {
        let base = scheme == .dark ? 0.45 : 0.12
        return prominence == .elevated ? base + 0.08 : base
    }
    private var ambientRadius: CGFloat {
        switch prominence {
        case .low: return 6
        case .regular: return 12
        case .elevated: return 24
        }
    }
    private var ambientY: CGFloat { prominence == .elevated ? 12 : 5 }

    private var glowColor: Color {
        guard let tint else { return .black.opacity(scheme == .dark ? 0.2 : 0.04) }
        return tint.opacity(scheme == .dark ? 0.45 : 0.32)
    }
    private var glowRadius: CGFloat { tint == nil ? 3 : (prominence == .elevated ? 22 : 14) }
}

extension View {
    /// Apply the Liquid Glass surface. `tint` adds a status wash + colored glow.
    func liquidGlass(
        cornerRadius: CGFloat = 18,
        prominence: GlassProminence = .regular,
        tint: Color? = nil,
        padding: CGFloat? = 14
    ) -> some View {
        modifier(LiquidGlassSurface(
            cornerRadius: cornerRadius,
            prominence: prominence,
            tint: tint,
            padding: padding
        ))
    }

    /// A soft colored glow halo (used on active/critical elements).
    func glassGlow(_ color: Color, radius: CGFloat = 14, active: Bool = true) -> some View {
        shadow(color: active ? color.opacity(0.5) : .clear, radius: radius)
    }
}

// MARK: - Glass segmented control (sliding glossy knob)
//
// Matches the reference "light / dark / auto" pill: a frosted track with a
// glazed knob that springs between segments via matchedGeometryEffect.

struct GlassSegment<Value: Hashable>: Identifiable {
    let value: Value
    let systemImage: String
    let label: String
    var id: Value { value }
}

struct GlassSegmentedControl<Value: Hashable>: View {
    let segments: [GlassSegment<Value>]
    @Binding var selection: Value
    var tint: Color = .accentColor

    @Namespace private var knob
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { seg in
                let isOn = seg.value == selection
                Button {
                    if reduceMotion {
                        selection = seg.value
                    } else {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                            selection = seg.value
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: seg.systemImage)
                        Text(seg.label)
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isOn {
                            knobShape
                                .matchedGeometryEffect(id: "glassKnob", in: knob)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .padding(4)
        .liquidGlass(cornerRadius: 999, prominence: .low, padding: 0)
    }

    private var knobShape: some View {
        Capsule(style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Capsule().fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [.white.opacity(0.18), .clear]
                            : [.white.opacity(0.85), .white.opacity(0.15)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(scheme == .dark ? 0.35 : 0.8), lineWidth: 1)
            }
            .shadow(color: tint.opacity(0.35), radius: 8)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

// MARK: - Glass button style (glazed pill)

struct GlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent: Bool = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background {
                let shape = Capsule(style: .continuous)
                ZStack {
                    if prominent, let tint {
                        shape.fill(tint.opacity(scheme == .dark ? 0.85 : 0.9))
                    } else {
                        shape.fill(.thinMaterial)
                        shape.fill((tint ?? .white).opacity(scheme == .dark ? 0.10 : 0.14))
                    }
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(scheme == .dark ? 0.16 : 0.5), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    ).blendMode(.plusLighter)
                    shape.strokeBorder(.white.opacity(scheme == .dark ? 0.28 : 0.7), lineWidth: 1)
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .shadow(color: (tint ?? .black).opacity(prominent ? 0.4 : 0.12), radius: configuration.isPressed ? 4 : 10, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
    static func glass(tint: Color, prominent: Bool = false) -> GlassButtonStyle {
        GlassButtonStyle(tint: tint, prominent: prominent)
    }
}
