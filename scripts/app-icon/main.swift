import AppKit
import SwiftUI

// MacStayOn app icon: a close-up of a laptop's front corner, lid partly open,
// the screen's warm light falling on the keyboard and trackpad — still awake.
// 1024×1024 on the macOS icon grid (824 tile). The laptop is a 3D model in mm,
// projected and shaded. Run ./scripts/make-app-icon.sh to regenerate every size.

extension Color {
    init(hex: UInt32, _ opacity: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

struct V3 { var x, y, z: Double }

enum Laptop {
    static let halfWidth = 160.0, halfDepth = 112.0, corner = 15.0
    static let baseHeight = 10.0, lidHeight = 5.0
    static let openAngle = 40.0 * Double.pi / 180
    static var deck: Double { baseHeight }

    static func roundedRect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, r: Double, steps: Int = 6)
        -> [(x: Double, y: Double, nx: Double, ny: Double)] {
        let centers = [(x1 - r, y1 - r, 0.0), (x0 + r, y1 - r, 90.0), (x0 + r, y0 + r, 180.0), (x1 - r, y0 + r, 270.0)]
        var pts: [(Double, Double, Double, Double)] = []
        for (cx, cy, start) in centers {
            for k in 0...steps {
                let a = (start + Double(k) / Double(steps) * 90) * .pi / 180
                pts.append((cx + r * cos(a), cy + r * sin(a), cos(a), sin(a)))
            }
        }
        return pts
    }
    static let outline = roundedRect(-halfWidth, -halfDepth, halfWidth, halfDepth, r: corner, steps: 16)

    /// A lid point (zLocal 0 = screen side), swung open about the hinge at the back.
    static func lid(_ x: Double, _ y: Double, _ zLocal: Double) -> V3 {
        let dy = y - halfDepth, dz = zLocal + 0.5
        return V3(x: x, y: halfDepth + dy * cos(openAngle) + dz * sin(openAngle),
                  z: baseHeight + dz * cos(openAngle) - dy * sin(openAngle))
    }
    static func lidNormal(_ n: V3) -> V3 {
        V3(x: n.x, y: n.y * cos(openAngle) + n.z * sin(openAngle), z: n.z * cos(openAngle) - n.y * sin(openAngle))
    }
}

struct Camera {
    let yaw = -30.0 * .pi / 180, pitch = 30.0 * .pi / 180
    let scale = 3.25
    let origin = CGPoint(x: 520, y: 548)

    func rotate(_ v: V3) -> V3 { V3(x: v.x * cos(yaw) - v.y * sin(yaw), y: v.x * sin(yaw) + v.y * cos(yaw), z: v.z) }
    func project(_ v: V3) -> CGPoint {
        let r = rotate(v)
        return CGPoint(x: origin.x + r.x * scale, y: origin.y - (r.y * sin(pitch) + r.z * cos(pitch)) * scale)
    }
    func facing(_ n: V3) -> Double { let r = rotate(n); return -r.y * cos(pitch) + r.z * sin(pitch) }
    func lambert(_ n: V3) -> Double {
        let r = rotate(n); let l = (0.55, -0.62, 0.56)
        return max(0, r.x * l.0 + r.y * l.1 + r.z * l.2)
    }
}

struct Scene: View {
    let cam = Camera()

    var body: some View {
        Canvas { ctx, _ in
            let o = Laptop.outline, n = o.count
            func poly(_ pts: [CGPoint]) -> Path { var p = Path(); p.addLines(pts); p.closeSubpath(); return p }
            func deckPath(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, r: Double, z: Double) -> Path {
                poly(Laptop.roundedRect(x0, y0, x1, y1, r: r).map { cam.project(V3(x: $0.x, y: $0.y, z: z)) })
            }
            func shade(_ rgb: (Double, Double, Double), _ k: Double) -> Color {
                Color(red: min(1, rgb.0 * k), green: min(1, rgb.1 * k), blue: min(1, rgb.2 * k))
            }
            func segNormal(_ i: Int) -> V3 {
                let a = o[i], b = o[(i + 1) % n]
                let nx = (a.nx + b.nx) / 2, ny = (a.ny + b.ny) / 2, len = max(1e-6, hypot(nx, ny))
                return V3(x: nx / len, y: ny / len, z: 0)
            }
            func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

            // Shadow and the screen's light spilling onto the desk in front.
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 28))
                l.fill(poly(o.map { cam.project(V3(x: $0.x, y: $0.y, z: 0)) }.map { CGPoint(x: $0.x + 8, y: $0.y + 28) }),
                       with: .color(.black.opacity(0.7)))
            }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 46))
                let a = cam.project(V3(x: -170, y: -118, z: 0)), b = cam.project(V3(x: 170, y: -118, z: 0))
                let c = cam.project(V3(x: 200, y: -230, z: 0)), d = cam.project(V3(x: -200, y: -230, z: 0))
                l.fill(poly([a, b, c, d]), with: .linearGradient(Gradient(colors: [Color(hex: 0xFFB04A, 0.2), Color(hex: 0xFF8A1E, 0)]),
                                                                 startPoint: mid(a, b), endPoint: mid(c, d)))
            }

            // Base outer walls.
            for i in 0..<n {
                let nrm = segNormal(i)
                guard cam.facing(nrm) > 0 else { continue }
                let a = o[i], b = o[(i + 1) % n]
                let top = [cam.project(V3(x: a.x, y: a.y, z: Laptop.baseHeight)), cam.project(V3(x: b.x, y: b.y, z: Laptop.baseHeight))]
                let bottom = [cam.project(V3(x: b.x, y: b.y, z: 0.8)), cam.project(V3(x: a.x, y: a.y, z: 0.8))]
                let k = 0.40 + 0.60 * cam.lambert(nrm)
                let g = Gradient(colors: [shade((0.62, 0.64, 0.70), k), shade((0.50, 0.53, 0.60), k * 0.8)])
                let p = poly(top + bottom)
                ctx.fill(p, with: .linearGradient(g, startPoint: mid(top[0], top[1]), endPoint: mid(bottom[0], bottom[1])))
                ctx.stroke(p, with: .linearGradient(g, startPoint: mid(top[0], top[1]), endPoint: mid(bottom[0], bottom[1])), lineWidth: 0.9)
            }

            // Deck: aluminium, warmed by the screen (brightest toward the hinge).
            let deckRing = o.map { cam.project(V3(x: $0.x, y: $0.y, z: Laptop.deck)) }
            let deck = poly(deckRing)
            let deckBack = cam.project(V3(x: 0, y: Laptop.halfDepth, z: Laptop.deck))
            let deckFront = cam.project(V3(x: 60, y: -Laptop.halfDepth, z: Laptop.deck))
            ctx.fill(deck, with: .linearGradient(Gradient(colors: [Color(hex: 0xE2C9A6), Color(hex: 0xBFB4A6), Color(hex: 0x9DA2AE)]),
                                                 startPoint: deckBack, endPoint: deckFront))
            // Polished chamfer around the deck edge.
            var rim = Path(); var on = false
            for i in 0..<n where true {
                let pt = deckRing[i]
                if cam.facing(segNormal(i)) > 0 { if on { rim.addLine(to: pt) } else { rim.move(to: pt); on = true } } else { on = false }
            }
            ctx.stroke(rim, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

            // Speaker grilles either side of the keyboard.
            for side in [-1.0, 1.0] {
                var x = 141.0
                while x <= 153.0 {
                    var y = -12.0
                    while y <= 96.0 {
                        let c = cam.project(V3(x: side * x, y: y, z: Laptop.deck))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.0, y: c.y - 0.7, width: 2.0, height: 1.4)), with: .color(Color(hex: 0x2A2622, 0.75)))
                        y += 2.4
                    }
                    x += 2.4
                }
            }

            // Keyboard well with a warm backlight showing between the keys.
            ctx.fill(deckPath(-137, -17, 137, 99, r: 4, z: Laptop.deck), with: .color(Color(hex: 0x2B1A0E)))
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 5))
                l.fill(deckPath(-134, -14, 134, 96, r: 4, z: Laptop.deck), with: .color(Color(hex: 0xFF9A2E, 0.85)))
            }

            // Keys: rows front (space bar) to back (function row), each scaled to the keyboard width.
            let rows: [(units: [Double], depth: Double)] = [
                ([1, 1, 1, 1.25, 5.25, 1.25, 1, 1, 1, 1], 15.5),
                ([2.3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.3], 15.5),
                ([1.8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.8], 15.5),
                ([1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5], 15.5),
                ([1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.5], 15.5),
                ([1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], 10.5),
            ]
            let kbX0 = -132.0, kbWidth = 264.0, gap = 2.3
            var rowY = -12.0
            for row in rows {
                let unit = (kbWidth - gap * Double(row.units.count - 1)) / row.units.reduce(0, +)
                var x = kbX0
                for u in row.units {
                    let w = u * unit
                    // Key side (a hint of travel) then the top.
                    ctx.fill(deckPath(x, rowY - 0.8, x + w, rowY + row.depth - 0.8, r: 2.2, z: Laptop.deck + 0.2), with: .color(Color(hex: 0x0E0E10)))
                    let top = deckPath(x, rowY, x + w, rowY + row.depth, r: 2.2, z: Laptop.deck + 1.0)
                    let back = cam.project(V3(x: x + w / 2, y: rowY + row.depth, z: Laptop.deck + 1))
                    let front = cam.project(V3(x: x + w / 2, y: rowY, z: Laptop.deck + 1))
                    ctx.fill(top, with: .linearGradient(Gradient(colors: [Color(hex: 0x3B3431), Color(hex: 0x1E1E22)]), startPoint: back, endPoint: front))
                    ctx.stroke(top, with: .color(Color(hex: 0xFFC27A, 0.22)), lineWidth: 0.8)
                    x += w + gap
                }
                rowY += row.depth + gap
            }

            // Trackpad: glass, catching the warm light.
            let pad = deckPath(-68, -103, 68, -25, r: 6, z: Laptop.deck + 0.1)
            ctx.fill(pad, with: .linearGradient(Gradient(colors: [Color(hex: 0xD8C2A4), Color(hex: 0xA9AAB2), Color(hex: 0x8E95A2)]),
                                                startPoint: cam.project(V3(x: 0, y: -25, z: Laptop.deck)), endPoint: cam.project(V3(x: 30, y: -103, z: Laptop.deck))))
            ctx.stroke(pad, with: .color(Color(hex: 0x5D6270, 0.6)), lineWidth: 1.4)
            ctx.stroke(deckPath(-67, -102, 67, -26, r: 5.5, z: Laptop.deck + 0.15), with: .color(.white.opacity(0.35)), lineWidth: 0.8)

            // Lid: the screen face (seen edge-on, glowing), then the edges.
            let screenRing = o.map { cam.project(Laptop.lid($0.x, $0.y, 0)) }
            let screenNormal = Laptop.lidNormal(V3(x: 0, y: 0, z: -1))
            if cam.facing(screenNormal) > 0 {
                ctx.fill(poly(screenRing), with: .color(Color(hex: 0x111114)))
                let glass = poly(Laptop.roundedRect(-150, -104, 150, 104, r: 9).map { cam.project(Laptop.lid($0.x, $0.y, -0.1)) })
                ctx.fill(glass, with: .linearGradient(Gradient(colors: [Color(hex: 0xFFF8E6), Color(hex: 0xFFD99A), Color(hex: 0xF7A94A)]),
                                                      startPoint: cam.project(Laptop.lid(0, 60, 0)), endPoint: cam.project(Laptop.lid(0, -104, 0))))
            }
            for i in 0..<n {
                let nrm = Laptop.lidNormal(segNormal(i))
                guard cam.facing(nrm) > 0 else { continue }
                let a = o[i], b = o[(i + 1) % n]
                let top = [cam.project(Laptop.lid(a.x, a.y, Laptop.lidHeight)), cam.project(Laptop.lid(b.x, b.y, Laptop.lidHeight))]
                let bottom = [cam.project(Laptop.lid(b.x, b.y, 0)), cam.project(Laptop.lid(a.x, a.y, 0))]
                let k = 0.45 + 0.55 * cam.lambert(nrm)
                let g = Gradient(colors: [shade((0.66, 0.69, 0.75), k), shade((0.66, 0.69, 0.75), k * 0.9)])
                let p = poly(top + bottom)
                ctx.fill(p, with: .linearGradient(g, startPoint: mid(top[0], top[1]), endPoint: mid(bottom[0], bottom[1])))
                ctx.stroke(p, with: .linearGradient(g, startPoint: mid(top[0], top[1]), endPoint: mid(bottom[0], bottom[1])), lineWidth: 0.9)
            }
            let lidTopNormal = Laptop.lidNormal(V3(x: 0, y: 0, z: 1))
            if cam.facing(lidTopNormal) > 0 {
                ctx.fill(poly(o.map { cam.project(Laptop.lid($0.x, $0.y, Laptop.lidHeight)) }), with: .color(Color(hex: 0xA6ADBB)))
            }

            // The screen's glow blooming over the deck.
            ctx.drawLayer { l in
                l.blendMode = .plusLighter
                l.addFilter(.blur(radius: 40))
                l.fill(poly(screenRing), with: .color(Color(hex: 0xFF9A2E, 0.32)))
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(RadialGradient(colors: [Color(hex: 0x263160), Color(hex: 0x141A36), Color(hex: 0x0B0F22)],
                                     center: UnitPoint(x: 0.5, y: 0.75), startRadius: 40, endRadius: 640))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
            Scene()
                .mask(RoundedRectangle(cornerRadius: 185, style: .continuous).frame(width: 824, height: 824))
        }
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
