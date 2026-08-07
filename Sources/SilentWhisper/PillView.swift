import SwiftUI

// MARK: - theme

enum Theme: String, CaseIterable, Identifiable {
    case glass, obsidian, chrome, pearl
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Glass refracts what is behind the panel instead of painting over it.
    var isGlass: Bool { self == .glass }

    /// The blob's fill. Glass is the default: a thin tint over the live backdrop.
    @ViewBuilder var fill: some View {
        switch self {
        case .glass:
            LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04), .white.opacity(0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .chrome:
            LinearGradient(stops: [
                .init(color: Color(hex: 0xf2f7ff), location: 0.00),
                .init(color: Color(hex: 0xa8b7cc), location: 0.26),
                .init(color: Color(hex: 0x2c3341), location: 0.58),
                .init(color: Color(hex: 0xdbe4f0), location: 0.82),
                .init(color: Color(hex: 0x6f7d90), location: 1.00),
            ], startPoint: .init(x: 0.1, y: 0), endPoint: .init(x: 0.9, y: 1))
        case .pearl:
            AngularGradient(colors: [0x7cf6ff, 0xb28cff, 0xff9ad5, 0xffd88a, 0x8affc1, 0x7cf6ff].map(Color.init(hex:)),
                            center: .center, angle: .degrees(200))
        case .obsidian:
            RadialGradient(colors: [Color(hex: 0x23262f), Color(hex: 0x05060a)],
                           center: .init(x: 0.34, y: 0.26), startRadius: 0, endRadius: 34)
        }
    }

    /// Obsidian is black glass — the gloss stays faint so the seam does the talking.
    var glossOpacity: Double {
        switch self {
        case .chrome: 0.62
        case .pearl: 0.48
        case .glass: 0.42
        case .obsidian: 0.16
        }
    }
}

// MARK: - state language (the --c1/--c2/--lift/--spd block from the mock)

extension PillState {
    var c1: Color {
        switch self {
        case .recording: Color(hex: 0x00d8ff)
        case .transcribing: Color(hex: 0xffb03a)
        case .done: Color(hex: 0x3ce87a)
        case .failed: Color(hex: 0xff4f5e)
        case .idle: Color(hex: 0x8a93a5)
        }
    }
    var c2: Color {
        switch self {
        case .recording: Color(hex: 0x6a5cff)
        case .transcribing: Color(hex: 0xff4fa3)
        case .done: Color(hex: 0x9fffc4)
        case .failed: Color(hex: 0xff9aa2)
        case .idle: Color(hex: 0x5c6474)
        }
    }
    /// How much halo and seam the state earns.
    var lift: Double {
        switch self {
        case .recording: 1.0
        case .transcribing: 0.9
        case .done: 0.75
        case .failed: 0.85
        case .idle: 0.26
        }
    }
    /// Multiplies the swarm period — smaller is faster.
    var speed: Double {
        switch self {
        case .transcribing: 0.34
        case .done: 1.6
        default: 1.0
        }
    }
    var coreDiameter: Double {
        switch self {
        case .recording: 44
        case .transcribing: 36
        case .done: 30
        default: 20
        }
    }
    var satelliteDiameter: Double {
        switch self {
        case .idle: 0
        case .failed: 0
        default: 14
        }
    }
    var caption: String {
        switch self {
        case .idle: "hold right ⌥ to talk"
        case .recording: "listening"
        case .transcribing: "transcribing"
        case .done: "pasted"
        case .failed(let why): why
        }
    }
}

// MARK: - the rig

/// One satellite: resting offset, period, phase delay. Straight off the `.r1` rules.
private struct Satellite {
    let dx, dy, period, delay: Double
}

private let satellites = [
    Satellite(dx: -40, dy: -22, period: 2.4, delay: 0.0),
    Satellite(dx: -33, dy:   8, period: 3.1, delay: 0.3),
    Satellite(dx:   9, dy: -27, period: 2.7, delay: 0.6),
    Satellite(dx:  22, dy:  10, period: 3.6, delay: 0.9),
    Satellite(dx:  38, dy:  -9, period: 2.9, delay: 1.2),
    Satellite(dx: -52, dy:   2, period: 3.3, delay: 1.5),
]

struct Blob { let x, y, r: Double }

/// The `swarm` keyframe: ease-in-out out to the far pose at 50%, back by 100%.
func swarmBlobs(t: Double, amp: Double, core: Double, sat: Double, speed: Double) -> [Blob] {
    var out = [Blob(x: 0, y: 0, r: core / 2 * (0.92 + 0.3 * amp))]
    guard sat > 0.4 else { return out }
    for s in satellites {
        let period = s.period * speed
        let phase = ((t - s.delay) / period).truncatingRemainder(dividingBy: 1)
        let f = (1 - cos(2 * .pi * (phase < 0 ? phase + 1 : phase))) / 2   // 0 → 1 → 0, eased
        let scale = (0.35 + 0.5 * amp) + f * ((0.8 + 0.85 * amp) - (0.35 + 0.5 * amp))
        out.append(Blob(x: s.dx + f * -7, y: s.dy + f * 5, r: sat / 2 * scale))
    }
    return out
}

/// Blurred-then-thresholded circles: neighbours melt into one another instead of overlapping.
private struct Goo: View, Animatable {
    var t: Double
    var amp: Double
    var core: Double
    var sat: Double
    var speed: Double

    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            // Blur must stay near satellite radius: wider and the small ones never
            // clear the threshold, tighter and nothing melts into the core.
            ctx.addFilter(.alphaThreshold(min: 0.4))
            ctx.addFilter(.blur(radius: 4.5))
            ctx.drawLayer { layer in
                let cx = size.width / 2, cy = size.height / 2
                for b in swarmBlobs(t: t, amp: amp, core: core, sat: sat, speed: speed) {
                    let rect = CGRect(x: cx + b.x - b.r, y: cy + b.y - b.r, width: b.r * 2, height: b.r * 2)
                    layer.fill(Path(ellipseIn: rect), with: .color(.white))
                }
            }
        }
    }
}

struct PillView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        TimelineView(.animation) { timeline in
            // Freezing t holds the swarm in its resting pose: the blob still answers your
            // voice through `amp`, it just stops orbiting.
            let t = engine.calmMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let st = engine.state
            let amp = engine.amp
            let goo = Goo(t: t, amp: amp, core: engine.core, sat: engine.sat, speed: st.speed)
            let halo = LinearGradient(colors: [st.c1, st.c2], startPoint: .leading, endPoint: .trailing)

            ZStack {
                // halo — the same swarm, blown out and blurred behind the body
                halo
                    .mask(goo)
                    .blur(radius: 14)
                    .scaleEffect(1.14 + 0.14 * amp)
                    .opacity(st.lift * (0.55 + 0.45 * amp))

                // Glass refracts the desktop behind the panel; the other themes are opaque
                // paint, so the material would only muddy them.
                if engine.theme.isGlass {
                    Rectangle().fill(.ultraThinMaterial).mask(goo)
                    halo.opacity(0.3 + 0.35 * amp).mask(goo).blendMode(.plusLighter)
                }

                engine.theme.fill
                    .mask(goo)

                if engine.theme.isGlass {
                    rim(st, goo: goo, amp: amp)
                    specular(amp: amp)
                }

                seam(st, amp: amp)
            }
            .frame(width: 220, height: 120)
            // drawingGroup() would rasterise the material and lose the backdrop.
            .compositingGroup()
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.toggle() }
        .help(engine.state.caption)
    }

    /// A lit edge around the whole shape: the goo filled with a light gradient, with a
    /// slightly smaller copy punched out of the middle.
    private func rim(_ st: PillState, goo: some View, amp: Double) -> some View {
        ZStack {
            LinearGradient(colors: [.white.opacity(0.9), st.c1.opacity(0.55), .white.opacity(0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .mask(goo)
            Color.black
                .mask(goo.scaleEffect(0.955))
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .opacity(0.5 + 0.4 * amp)
    }

    /// The tight highlight that sells a curved, wet surface.
    private func specular(amp: Double) -> some View {
        let d = engine.core * (0.92 + 0.3 * amp)
        return Ellipse()
            .fill(.white)
            .frame(width: d * 0.3, height: d * 0.19)
            .blur(radius: 3)
            .opacity(0.75)
            .offset(x: -d * 0.2, y: -d * 0.26)
    }

    /// The iridescent seam plus the top gloss — never gooed, so they stay crisp.
    private func seam(_ st: PillState, amp: Double) -> some View {
        let d = engine.core * (0.92 + 0.3 * amp)
        return ZStack {
            LinearGradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: st.c1, location: 0.20),
                .init(color: .white, location: 0.50),
                .init(color: st.c2, location: 0.80),
                .init(color: .clear, location: 1.00),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: d * 0.88, height: 3)
            .scaleEffect(x: 0.55 + 0.5 * amp, y: 1, anchor: .center)
            .blur(radius: 2.4)
            .shadow(color: st.c1.opacity(0.8), radius: 9)
            .opacity(st.lift * (0.6 + 0.4 * amp))

            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(engine.theme.glossOpacity), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: d * 0.64, height: d * 0.34)
                .offset(y: -d * 0.24)
        }
        .frame(width: d, height: d)
    }
}

// MARK: - self-check

/// `SilentWhisper --selftest`. Guards the swarm maths — the one place a silent
/// sign or wrap error would just look like a slightly wrong animation.
func runSelfTest() {
    let core = 44.0, sat = 14.0

    // Idle: core only, no satellites.
    assert(swarmBlobs(t: 0, amp: 0, core: 20, sat: 0, speed: 1).count == 1)
    // Active: core + all six.
    assert(swarmBlobs(t: 0, amp: 0.5, core: core, sat: sat, speed: 1).count == 7)

    // The cycle repeats exactly one period per satellite, and negative t must not
    // fall off the end of the phase wrap.
    let a = swarmBlobs(t: 0.7, amp: 0.5, core: core, sat: sat, speed: 1)
    let b = swarmBlobs(t: 0.7 + 2.4, amp: 0.5, core: core, sat: sat, speed: 1)
    assert(abs(a[1].x - b[1].x) < 1e-9, "satellite 1 should repeat every 2.4 s")
    for blob in swarmBlobs(t: -3, amp: 0.3, core: core, sat: sat, speed: 1) {
        assert(blob.r.isFinite && blob.r >= 0, "negative time produced \(blob.r)")
    }

    // Louder input throws the satellites wider and swells the core.
    let quiet = swarmBlobs(t: 1.2, amp: 0.0, core: core, sat: sat, speed: 1)
    let loud  = swarmBlobs(t: 1.2, amp: 1.0, core: core, sat: sat, speed: 1)
    assert(loud[0].r > quiet[0].r, "core should swell with the voice")
    assert(loud[3].r > quiet[3].r, "satellites should swell with the voice")

    // Satellites stay inside the 220×120 panel at full tilt.
    for blob in loud {
        assert(abs(blob.x) + blob.r <= 110 && abs(blob.y) + blob.r <= 60, "blob escapes the panel")
    }

    // Model substitution: prefer the best downloaded model at or below what was asked for,
    // and only reach upward when there is nothing below.
    assert(fallbackModel(for: "small", from: ["small", "tiny"]) == "small", "downloaded model must win")
    assert(fallbackModel(for: "large-v3_turbo", from: ["tiny", "base", "small"]) == "small")
    assert(fallbackModel(for: "tiny", from: ["medium"]) == "medium", "reach up when nothing is below")
    assert(fallbackModel(for: "small", from: []) == nil, "nothing downloaded means nothing to use")
    assert(fallbackModel(for: "small", from: ["nonsense"]) == nil, "unknown names are not candidates")

    print("selftest ok")
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}
