import SwiftUI

/// Everything the hanging lamp animates. There are no repeating animations, so a
/// lamp that is just hanging there costs no CPU.
final class LampModel: ObservableObject {
    /// Vertical offset of the lamp on its cord (negative = pulled up out of view).
    @Published var drop: CGFloat = 0
    @Published var opacity: Double = 0
    /// 0 = chain at rest, 1 = pulled all the way down.
    @Published var pull: CGFloat = 0
    /// 0 = bulb dark, 1 = fully lit (in between for the flicker).
    @Published var lit: Double = 0
    /// Chain swing in degrees, pivoting where the chain leaves the socket.
    @Published var sway: Double = 0
}

/// Layout of the lamp inside its transparent panel, in SwiftUI points (y down).
/// The panel's top edge sits at the top of the screen, so the first `topInset`
/// points are behind the menu bar and the cord appears to come out of it.
struct LampGeometry: Equatable {
    var topInset: CGFloat

    let width: CGFloat = 170
    let socketHeight: CGFloat = 11
    let shadeWidth: CGFloat = 68
    let shadeHeight: CGFloat = 40
    let bulbDiameter: CGFloat = 26
    /// Chain hangs this far right of the bulb's center.
    let chainOffsetX: CGFloat = 17
    /// Visible chain below the shade's rim, at rest.
    let chainVisibleLength: CGFloat = 58
    /// Part of the chain hidden up inside the shade; it slides out when pulled.
    let chainHiddenLength: CGFloat = 26
    let pullDistance: CGFloat = 16
    let beadPitch: CGFloat = 4.5
    let knobSize = CGSize(width: 9, height: 15)

    var centerX: CGFloat { width / 2 }
    var cordBottom: CGFloat { topInset + 28 }
    var shadeTop: CGFloat { cordBottom + 7 }
    var rimY: CGFloat { shadeTop + shadeHeight }
    /// The bulb hangs inside the dome: its top is hidden by the shade and the
    /// rest shows through the opening and just below the front lip.
    var bulbCenterY: CGFloat { rimY - 1 }
    var chainX: CGFloat { centerX + chainOffsetX }
    var chainTop: CGFloat { rimY - chainHiddenLength }
    var chainLength: CGFloat { chainHiddenLength + chainVisibleLength }
    var beadCount: Int { Int(chainLength / beadPitch) }
    /// Center of the pull knob at rest.
    var knobCenter: CGPoint {
        CGPoint(x: chainX, y: rimY + chainVisibleLength + knobSize.height / 2 + 1)
    }
    var height: CGFloat { rimY + 118 }
    /// How far up the lamp starts before it drops in.
    var dropDistance: CGFloat { rimY + 110 }
}

/// A dark enamel pendant lamp with a brass ball-chain pull switch, drawn with
/// gradients so it reads as 3D, plus a soft warm glow when lit.
struct LampView: View {
    @ObservedObject var model: LampModel
    let geometry: LampGeometry

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            // The lamp moves on its cord; the ceiling cap stays put, in front of the cord.
            ZStack(alignment: .topLeading) {
                lightCone
                halo
                cord
                chain
                socket
                shade
                rim
                bulb
            }
            .offset(y: model.drop)
            // Nothing shows in the menu bar strip (it is see-through on current
            // macOS): the cord starts at the cap, and the lamp lowers out of it.
            .mask {
                Rectangle()
                    .frame(width: g.width, height: g.height - g.topInset)
                    .position(x: g.width / 2, y: g.topInset + (g.height - g.topInset) / 2)
            }
            canopy
        }
        .frame(width: g.width, height: g.height, alignment: .topLeading)
        // Flatten first: otherwise each layer fades on its own and the shade
        // shows through the bulb mid-fade.
        .compositingGroup()
        .opacity(model.opacity)
        .accessibilityHidden(true)
    }

    // MARK: Light

    private var lightCone: some View {
        let g = geometry
        let height = g.height - g.rimY
        return LightConeShape()
            .fill(LinearGradient(
                colors: [LampPalette.warm.opacity(0.30), LampPalette.warm.opacity(0.08), .clear],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: 164, height: height)
            .blur(radius: 3)
            .position(x: g.centerX, y: g.rimY + height / 2)
            .opacity(model.lit)
    }

    private var halo: some View {
        let g = geometry
        return Circle()
            .fill(RadialGradient(
                colors: [LampPalette.warmCore.opacity(0.75), LampPalette.warm.opacity(0.28), .clear],
                center: .center,
                startRadius: 4,
                endRadius: 64
            ))
            .frame(width: 128, height: 128)
            .position(x: g.centerX, y: g.bulbCenterY + 4)
            .opacity(model.lit)
    }

    // MARK: Hardware

    /// Ceiling cap, tucked against the bottom edge of the menu bar (or the
    /// notch band in full-screen apps).
    private var canopy: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LampPalette.brassAcross)
            .frame(width: 30, height: 7)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            .position(x: geometry.centerX, y: geometry.topInset + 2.5)
    }

    /// Long enough to reach far above the window, so it never shows a loose end
    /// while the lamp drops in.
    private var cord: some View {
        let g = geometry
        let extra: CGFloat = 420
        let length = g.cordBottom + 2 + extra
        return Rectangle()
            .fill(LinearGradient(
                colors: [Color(lampHex: 0x0B0B0C), Color(lampHex: 0x5A5F66), Color(lampHex: 0x0B0B0C)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(width: 2.4, height: length)
            .position(x: g.centerX, y: length / 2 - extra)
    }

    private var socket: some View {
        let g = geometry
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(LampPalette.brassAcross)
            .frame(width: 14, height: g.socketHeight)
            .position(x: g.centerX, y: g.cordBottom + g.socketHeight / 2 - 1)
    }

    private var shade: some View {
        let g = geometry
        return ZStack {
            Rectangle().fill(LampPalette.enamelAcross)
            // Light from above: brighter crown, darker toward the rim.
            Rectangle().fill(LinearGradient(
                colors: [.white.opacity(0.14), .clear, .black.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom
            ))
            // Glossy streak.
            Ellipse()
                .fill(.white.opacity(0.38))
                .frame(width: 7, height: 26)
                .rotationEffect(.degrees(26))
                .offset(x: -17, y: 5)
                .blur(radius: 1.6)
            // Warm bounce on the lower edge when lit.
            Rectangle()
                .fill(LinearGradient(
                    colors: [.clear, LampPalette.warm.opacity(0.35)],
                    startPoint: .center,
                    endPoint: .bottom
                ))
                .opacity(model.lit)
        }
        .frame(width: g.shadeWidth, height: g.shadeHeight)
        .clipShape(ShadeShape())
        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
        .position(x: g.centerX, y: g.shadeTop + g.shadeHeight / 2)
    }

    /// Open bottom of the shade: the inside of the dome (lit when on) ringed in
    /// brass. The bulb is drawn over this, so no band ever crosses it.
    private var rim: some View {
        let g = geometry
        return ZStack {
            Ellipse()
                .fill(RadialGradient(
                    colors: [Color(lampHex: 0x2E2A25), Color(lampHex: 0x121110)],
                    center: .center,
                    startRadius: 0,
                    endRadius: g.shadeWidth / 2
                ))
            Ellipse()
                .fill(RadialGradient(
                    colors: [Color(lampHex: 0xF6C267), Color(lampHex: 0xD98E34), Color(lampHex: 0x8A4F18)],
                    center: .center,
                    startRadius: 0,
                    endRadius: g.shadeWidth / 2
                ))
                .opacity(model.lit)
            Ellipse()
                .stroke(LampPalette.brassAcross, lineWidth: 1.8)
        }
        .frame(width: g.shadeWidth, height: 10)
        .position(x: g.centerX, y: g.rimY)
    }

    private var bulb: some View {
        let g = geometry
        return ZStack {
            // Opal (milky) glass: fully opaque, so nothing behind it shows through.
            Circle().fill(RadialGradient(
                colors: [.white, Color(lampHex: 0xECEAE4), Color(lampHex: 0xC9C6BE), Color(lampHex: 0x8E8B84)],
                center: UnitPoint(x: 0.4, y: 0.55),
                startRadius: 0,
                endRadius: g.bulbDiameter * 0.56
            ))
            Circle().fill(RadialGradient(
                colors: [.white, Color(lampHex: 0xFFFBEA), Color(lampHex: 0xFFE7A8), Color(lampHex: 0xF4AE4C)],
                center: UnitPoint(x: 0.5, y: 0.55),
                startRadius: 0,
                endRadius: g.bulbDiameter * 0.56
            ))
            .opacity(model.lit)
            // Crisp glass edge so the bulb reads as a solid object inside the dome.
            Circle()
                .strokeBorder(Color(lampHex: 0x6F6A62).opacity(0.55 * (1 - model.lit)), lineWidth: 0.9)
            Circle()
                .strokeBorder(Color(lampHex: 0xC77B26).opacity(0.7 * model.lit), lineWidth: 0.9)
            // Glass highlight on the visible lower half.
            Ellipse()
                .fill(.white.opacity(0.7))
                .frame(width: 5, height: 3)
                .offset(x: -6, y: 6)
                .blur(radius: 0.6)
        }
        .frame(width: g.bulbDiameter, height: g.bulbDiameter)
        .shadow(color: LampPalette.warm.opacity(0.9 * model.lit), radius: 9)
        .position(x: g.centerX, y: g.bulbCenterY)
        // Inside the dome: visible only through the opening and below the rim.
        .mask {
            ZStack(alignment: .topLeading) {
                Ellipse()
                    .frame(width: g.shadeWidth - 2, height: 10)
                    .position(x: g.centerX, y: g.rimY)
                Rectangle()
                    .frame(width: g.width, height: g.height - g.rimY)
                    .position(x: g.width / 2, y: g.rimY + (g.height - g.rimY) / 2)
            }
            .frame(width: g.width, height: g.height, alignment: .topLeading)
        }
    }


    /// Ball chain ending in a brass pull. Drawn behind the shade so pulling it
    /// slides more chain out from inside; swings about where it leaves the socket.
    private var chain: some View {
        let g = geometry
        let frameHeight = g.chainLength + g.knobSize.height + 2
        return VStack(spacing: g.beadPitch - 3.4) {
            ForEach(0..<g.beadCount, id: \.self) { _ in
                Circle()
                    .fill(LampPalette.bead)
                    .frame(width: 3.4, height: 3.4)
            }
            PullKnob()
                .frame(width: g.knobSize.width, height: g.knobSize.height)
        }
        .frame(width: 16, height: frameHeight, alignment: .top)
        .shadow(color: .black.opacity(0.35), radius: 1, x: 0.5, y: 1)
        .rotationEffect(.degrees(model.sway), anchor: .top)
        .offset(y: model.pull * g.pullDistance)
        .position(x: g.chainX, y: g.chainTop + frameHeight / 2)
        // The chain only shows below the shade's opening, never through its sides.
        .mask {
            let visibleTop = g.rimY - 2
            Rectangle()
                .frame(width: g.width, height: g.height - visibleTop)
                .position(x: g.width / 2, y: visibleTop + (g.height - visibleTop) / 2)
        }
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
                    endRadius: 10
                ))
                .padding(.top, 2)
            Capsule()
                .fill(Color(lampHex: 0x6E4C17))
                .frame(width: 5, height: 3)
            Ellipse()
                .fill(.white.opacity(0.65))
                .frame(width: 2, height: 4.5)
                .offset(x: -1.6, y: 5)
                .blur(radius: 0.4)
        }
    }
}

/// Bell-shaped enamel shade: narrow crown flaring out to a wide rim.
private struct ShadeShape: Shape {
    func path(in r: CGRect) -> Path {
        let crown = r.width * 0.26
        var p = Path()
        p.move(to: CGPoint(x: r.midX - crown / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + crown / 2, y: r.minY))
        p.addCurve(
            to: CGPoint(x: r.maxX, y: r.maxY),
            control1: CGPoint(x: r.midX + crown / 2 + r.width * 0.06, y: r.minY + r.height * 0.5),
            control2: CGPoint(x: r.maxX - r.width * 0.03, y: r.maxY - r.height * 0.3)
        )
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addCurve(
            to: CGPoint(x: r.midX - crown / 2, y: r.minY),
            control1: CGPoint(x: r.minX + r.width * 0.03, y: r.maxY - r.height * 0.3),
            control2: CGPoint(x: r.midX - crown / 2 - r.width * 0.06, y: r.minY + r.height * 0.5)
        )
        p.closeSubpath()
        return p
    }
}

/// Beam of light spreading down from the rim.
private struct LightConeShape: Shape {
    func path(in r: CGRect) -> Path {
        let top = r.width * 0.38
        var p = Path()
        p.move(to: CGPoint(x: r.midX - top / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + top / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private enum LampPalette {
    static let warm = Color(lampHex: 0xFFB347)
    static let warmCore = Color(lampHex: 0xFFD27A)

    static let brassAcross = LinearGradient(
        stops: [
            .init(color: Color(lampHex: 0x5A3A10), location: 0),
            .init(color: Color(lampHex: 0xB88534), location: 0.25),
            .init(color: Color(lampHex: 0xF2D48D), location: 0.45),
            .init(color: Color(lampHex: 0xC4913F), location: 0.65),
            .init(color: Color(lampHex: 0x6B4714), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let enamelAcross = LinearGradient(
        stops: [
            .init(color: Color(lampHex: 0x0D0F11), location: 0),
            .init(color: Color(lampHex: 0x2C3238), location: 0.22),
            .init(color: Color(lampHex: 0x6B747E), location: 0.36),
            .init(color: Color(lampHex: 0x3A4047), location: 0.52),
            .init(color: Color(lampHex: 0x1A1D21), location: 0.8),
            .init(color: Color(lampHex: 0x0A0B0D), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let bead = RadialGradient(
        colors: [Color(lampHex: 0xFFF5D6), Color(lampHex: 0xD7AE5C), Color(lampHex: 0x7A5418)],
        center: UnitPoint(x: 0.35, y: 0.3),
        startRadius: 0,
        endRadius: 2.4
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
