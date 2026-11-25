import SwiftUI

/// Everything the glow and pull chain animate. There are no repeating
/// animations, so a chain that is just hanging there costs no CPU.
final class LampModel: ObservableObject {
    /// Vertical offset of the chain (negative = drawn up into the menu bar).
    @Published var drop: CGFloat = 0
    @Published var opacity: Double = 0
    /// 0 = chain at rest, 1 = pulled all the way down.
    @Published var pull: CGFloat = 0
    /// 0 = no glow, 1 = full glow (in between for the flicker).
    @Published var lit: Double = 0
    /// Chain swing in degrees, pivoting up behind the menu bar.
    @Published var sway: Double = 0
}

/// Layout inside the transparent panel, in SwiftUI points (y down). The panel's
/// top edge sits at the top of the screen; nothing is drawn in the first
/// `topInset` points (the menu bar), so the chain and the glow seem to come
/// from under it.
struct LampGeometry: Equatable {
    var topInset: CGFloat

    let width: CGFloat = 240
    /// Chain showing below the menu bar, at rest.
    let chainVisibleLength: CGFloat = 74
    /// Chain hidden up behind the menu bar; it slides out when pulled.
    let chainHiddenLength: CGFloat = 26
    let pullDistance: CGFloat = 16
    let beadPitch: CGFloat = 4.5
    let beadSize: CGFloat = 3.6
    let knobSize = CGSize(width: 10, height: 16)
    /// Half-width / height of the glow spilling down from the menu bar.
    let glowSize = CGSize(width: 118, height: 150)

    var chainX: CGFloat { width / 2 }
    var chainTop: CGFloat { topInset - chainHiddenLength }
    var chainLength: CGFloat { chainHiddenLength + chainVisibleLength }
    var beadCount: Int { Int(chainLength / beadPitch) }
    /// Center of the pull knob at rest.
    var knobCenter: CGPoint {
        CGPoint(x: chainX, y: topInset + chainVisibleLength + knobSize.height / 2 + 1)
    }
    var height: CGFloat { topInset + glowSize.height + 10 }
    /// How far the chain draws up to disappear behind the menu bar.
    var dropDistance: CGFloat { chainVisibleLength + knobSize.height + 6 }
}

/// A warm glow spilling from under the menu bar, with a brass ball-chain pull
/// switch hanging through it.
struct LampView: View {
    @ObservedObject var model: LampModel
    let geometry: LampGeometry

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            glow
            chain
        }
        .frame(width: g.width, height: g.height, alignment: .topLeading)
        // Nothing shows in the menu bar strip (it is see-through on current macOS).
        .mask {
            Rectangle()
                .frame(width: g.width, height: g.height - g.topInset)
                .position(x: g.width / 2, y: g.topInset + (g.height - g.topInset) / 2)
        }
        // Flatten first so a fade never lets one layer show through another.
        .compositingGroup()
        .opacity(model.opacity)
        .accessibilityHidden(true)
    }

    private var glow: some View {
        let g = geometry
        return ZStack {
            Rectangle()
                .fill(EllipticalGradient(
                    stops: [
                        .init(color: LampPalette.warmCore.opacity(0.55), location: 0),
                        .init(color: LampPalette.warm.opacity(0.30), location: 0.35),
                        .init(color: LampPalette.warm.opacity(0.08), location: 0.7),
                        // Fade to transparent amber, not .clear (black), so the
                        // edge never turns gray on light backgrounds.
                        .init(color: LampPalette.warm.opacity(0), location: 1),
                    ],
                    center: .center,
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.5
                ))
                .frame(width: g.glowSize.width * 2, height: g.glowSize.height * 2)
            // Brighter seam where the light spills out from under the menu bar.
            Ellipse()
                .fill(LampPalette.warmCore.opacity(0.6))
                .frame(width: 120, height: 18)
                .blur(radius: 7)
        }
        .position(x: g.chainX, y: g.topInset)
        .opacity(model.lit)
    }

    /// Ball chain ending in a brass pull. Pulling slides more chain out from
    /// behind the menu bar; it swings about a point hidden up there.
    private var chain: some View {
        let g = geometry
        let frameHeight = g.chainLength + g.knobSize.height + 2
        return VStack(spacing: g.beadPitch - g.beadSize) {
            ForEach(0..<g.beadCount, id: \.self) { _ in
                Circle()
                    .fill(LampPalette.bead)
                    .frame(width: g.beadSize, height: g.beadSize)
            }
            PullKnob()
                .frame(width: g.knobSize.width, height: g.knobSize.height)
        }
        .frame(width: 18, height: frameHeight, alignment: .top)
        .shadow(color: .black.opacity(0.4), radius: 1.2, x: 0.5, y: 1)
        .rotationEffect(.degrees(model.sway), anchor: .top)
        .offset(y: model.pull * g.pullDistance + model.drop)
        .position(x: g.chainX, y: g.chainTop + frameHeight / 2)
    }
}

/// Brass teardrop pull at the end of the chain.
private struct PullKnob: View {
    var body: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(RadialGradient(
                    colors: [Color(lampHex: 0xFFF3CC), Color(lampHex: 0xE2B660), Color(lampHex: 0x9C6C22), Color(lampHex: 0x573A0F)],
                    center: UnitPoint(x: 0.35, y: 0.4),
                    startRadius: 0,
                    endRadius: 11
                ))
                .padding(.top, 2)
            Capsule()
                .fill(Color(lampHex: 0x6E4C17))
                .frame(width: 5, height: 3)
            Ellipse()
                .fill(.white.opacity(0.65))
                .frame(width: 2.2, height: 5)
                .offset(x: -1.8, y: 5)
                .blur(radius: 0.4)
        }
    }
}

private enum LampPalette {
    static let warm = Color(lampHex: 0xFFB347)
    static let warmCore = Color(lampHex: 0xFFD27A)

    static let bead = RadialGradient(
        colors: [Color(lampHex: 0xFFF5D6), Color(lampHex: 0xD7AE5C), Color(lampHex: 0x7A5418)],
        center: UnitPoint(x: 0.35, y: 0.3),
        startRadius: 0,
        endRadius: 2.5
    )
}

private extension Color {
    init(lampHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
