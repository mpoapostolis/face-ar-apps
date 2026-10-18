import SwiftUI
import simd

enum Category: String, CaseIterable, Identifiable {
    case looks, skin, lips, eyeshadow, liner, blush, brows
    var id: String { rawValue }
    var title: String {
        switch self {
        case .looks: return "Looks"
        case .skin: return "Δέρμα"
        case .lips: return "Κραγιόν"
        case .eyeshadow: return "Σκιές"
        case .liner: return "Eyeliner"
        case .blush: return "Ρουζ"
        case .brows: return "Φρύδια"
        }
    }
    var shades: [Shade] {
        switch self {
        case .lips: return Palette.lips
        case .eyeshadow: return Palette.eyeshadow
        case .liner: return Palette.liner
        case .blush: return Palette.blush
        case .looks, .skin, .brows: return []
        }
    }
}

/// Live status of one zone of the brow guide.
struct BrowZone: Identifiable, Equatable {
    let id: Int
    let name: String
    var visible: Bool
    var stray: Double      // share of the zone that has hair to remove (0...1)
    var limit: Double      // share below which the zone counts as clean

    var clean: Bool { stray < limit }
    var label: String {
        guard visible else { return "\(name) —" }
        return clean ? "\(name) ✓" : "\(name): βγάλε"
    }
}

final class MakeupSettings: ObservableObject {
    @Published var selected: Category = .looks

    @Published var lipShade: Shade? = Palette.lips[0]
    @Published var lipIntensity: Double = 0.85
    @Published var lipFinish: LipFinish = .satin

    @Published var shadowShade: Shade?
    @Published var shadowIntensity: Double = 0.6
    @Published var shimmer: Double = 0.4

    @Published var linerShade: Shade?
    @Published var linerIntensity: Double = 0.9
    @Published var linerThickness: Double = 1.0
    @Published var linerWing: Double = 1.0

    @Published var blushShade: Shade?
    @Published var blushIntensity: Double = 0.45
    /// Where the blush sits; follows the face shape once it is measured.
    @Published var blushPlacement = BlushPlacement.standard

    // Skin
    @Published var smoothing: Double = 0.3
    @Published var evenTone: Double = 0.3
    @Published var glow: Double = 0
    @Published var contour: Double = 0

    // Before / after: left of the split the camera stays untouched.
    @Published var splitOn = false
    @Published var split: Double = 0.5

    /// 0...1 while the app learns the person's nose sides, pupils and brows.
    @Published var browCalibration: Double = 0
    @Published var browZones: [BrowZone] = []

    // What suits this face
    /// 0...1 while the face is being measured.
    @Published var measureProgress: Double = 0
    @Published private(set) var profile: FaceProfile?
    @Published private(set) var advice: Recommendation?
    /// The undertone picked by hand; nil = use the measured one.
    @Published var undertoneChoice: Undertone? { didSet { refreshAdvice() } }
    /// Set to measure the face again (new light, another person); the renderer clears it.
    var remeasureRequested = false

    /// Name of the look that is on, until something is changed by hand.
    @Published var activeLook: String?

    @Published var faceVisible = false
    @Published var unsupported = false
    @Published var regionsFailed = false
    @Published var debugMasks = false

    weak var renderer: MakeupRenderer?

    func setProfile(_ p: FaceProfile?) {
        profile = p
        refreshAdvice()
    }

    private func refreshAdvice() {
        guard var p = profile else { advice = nil; return }
        if let u = undertoneChoice { p.undertone = u }
        let a = Advisor.recommend(p)
        advice = a
        blushPlacement = a.blush
    }

    func remeasure() {
        remeasureRequested = true
        measureProgress = 0
        setProfile(nil)
    }

    func shade(for c: Category) -> Shade? {
        switch c {
        case .lips: return lipShade
        case .eyeshadow: return shadowShade
        case .liner: return linerShade
        case .blush: return blushShade
        case .looks, .skin, .brows: return nil
        }
    }

    /// Whether a category has something on (shown as a dot on its tab).
    func isOn(_ c: Category) -> Bool {
        switch c {
        case .skin: return smoothing > 0.01 || evenTone > 0.01 || glow > 0.01 || contour > 0.01
        case .looks, .brows: return false
        default: return shade(for: c) != nil
        }
    }

    /// Puts on a complete look.
    func apply(_ look: Look) {
        lipShade = look.lip
        lipFinish = look.lipFinish
        lipIntensity = look.lipIntensity
        blushShade = look.blush
        blushIntensity = look.blushIntensity
        shadowShade = look.shadow
        shadowIntensity = look.shadowIntensity
        shimmer = look.shimmer
        linerShade = look.liner
        if look.liner != nil { linerWing = look.wing }
        smoothing = look.smooth
        evenTone = look.smooth
        glow = look.glow
        contour = look.contour
        activeLook = look.name
    }

    func setShade(_ s: Shade?, for c: Category) {
        activeLook = nil
        switch c {
        case .lips: lipShade = s
        case .eyeshadow: shadowShade = s
        case .liner: linerShade = s
        case .blush: blushShade = s
        case .looks, .skin, .brows: break
        }
    }

    func intensityBinding(for c: Category) -> Binding<Double> {
        switch c {
        case .lips: return Binding(get: { self.lipIntensity }, set: { self.lipIntensity = $0 })
        case .eyeshadow: return Binding(get: { self.shadowIntensity }, set: { self.shadowIntensity = $0 })
        case .liner: return Binding(get: { self.linerIntensity }, set: { self.linerIntensity = $0 })
        case .blush: return Binding(get: { self.blushIntensity }, set: { self.blushIntensity = $0 })
        case .looks, .skin, .brows: return .constant(0)
        }
    }
}
