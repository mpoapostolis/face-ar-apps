import Foundation
import simd

enum FaceShape: String {
    case oval, round, long, square, heart

    var title: String {
        switch self {
        case .oval: return "Οβάλ"
        case .round: return "Στρογγυλό"
        case .long: return "Μακρόστενο"
        case .square: return "Τετράγωνο"
        case .heart: return "Καρδιά"
        }
    }
}

enum EyeSpacing: String {
    case close, average, wide

    var title: String {
        switch self {
        case .close: return "κοντά μεταξύ τους"
        case .average: return "σε ισορροπημένη απόσταση"
        case .wide: return "μακριά μεταξύ τους"
        }
    }
}

enum EyeTilt: String {
    case down, straight, up

    var title: String {
        switch self {
        case .down: return "η εξωτερική γωνία πέφτει ελαφρά"
        case .straight: return "ίσια"
        case .up: return "η εξωτερική γωνία ανεβαίνει"
        }
    }
}

/// Where the blush sits on the cheek.
struct BlushPlacement: Equatable {
    var out: Float      // centre x, as a multiple of the eye centre x
    var down: Float     // centre y, as a share of the eye-to-mouth height below the eye
    var rx: Float       // radii in metres, for an average-sized face
    var ry: Float
    var tilt: Float     // lift towards the temples (radians)

    static let standard = BlushPlacement(out: 1.22, down: 0.47, rx: 0.021, ry: 0.014, tilt: 0.35)
}

/// A complete set of products to put on with one tap.
struct Look: Equatable, Identifiable {
    var name: String
    var lip: Shade?
    var lipFinish = LipFinish.satin
    var lipIntensity = 0.8
    var blush: Shade?
    var blushIntensity = 0.4
    var shadow: Shade?
    var shadowIntensity = 0.5
    var shimmer = 0.3
    var liner: Shade?
    var wing = 0.6
    var smooth = 0.35
    var glow = 0.25
    var contour = 0.0

    var id: String { name }
    var shades: [Shade] { [lip, blush, shadow, liner].compactMap { $0 } }

    var summary: String {
        var parts: [String] = []
        if let lip { parts.append("Κραγιόν \(lip.name)") }
        if let blush { parts.append("ρουζ \(blush.name)") }
        if let shadow { parts.append("σκιά \(shadow.name)") }
        if let liner { parts.append("eyeliner \(liner.name)") }
        return parts.isEmpty ? "Μόνο το δέρμα σου" : parts.joined(separator: " · ")
    }
}

enum Looks {
    private static func lip(_ n: String) -> Shade? { Palette.lips.first { $0.name == n } }
    private static func blush(_ n: String) -> Shade? { Palette.blush.first { $0.name == n } }
    private static func shadow(_ n: String) -> Shade? { Palette.eyeshadow.first { $0.name == n } }
    private static func liner(_ n: String) -> Shade? { Palette.liner.first { $0.name == n } }

    static let bare = Look(name: "Χωρίς", smooth: 0, glow: 0)

    static let presets: [Look] = [
        Look(name: "Φυσικό", lip: lip("Nude"), lipIntensity: 0.6, blush: blush("Ροδακινί"), blushIntensity: 0.3,
             smooth: 0.35, glow: 0.2),
        Look(name: "Ρομαντικό", lip: lip("Ροζ"), lipIntensity: 0.75, blush: blush("Ροζ"), blushIntensity: 0.45,
             shadow: shadow("Rose gold"), shadowIntensity: 0.5, shimmer: 0.5, liner: liner("Καφέ"), wing: 0.4,
             smooth: 0.4, glow: 0.35),
        Look(name: "Κόκκινο", lip: lip("Κλασικό κόκκινο"), lipFinish: .matte, lipIntensity: 0.9,
             blush: blush("Ροδακινί"), blushIntensity: 0.3, shadow: shadow("Champagne"), shadowIntensity: 0.35,
             shimmer: 0.2, liner: liner("Μαύρο"), wing: 1.0, smooth: 0.4, glow: 0.2, contour: 0.2),
        Look(name: "Smoky", lip: lip("Mauve"), lipIntensity: 0.7, blush: blush("Bronze"), blushIntensity: 0.3,
             shadow: shadow("Smoky"), shadowIntensity: 0.7, shimmer: 0.3, liner: liner("Μαύρο"), wing: 0.8,
             smooth: 0.4, glow: 0.25, contour: 0.3),
        Look(name: "Καλοκαίρι", lip: lip("Κοραλί"), lipFinish: .gloss, lipIntensity: 0.7, blush: blush("Κοραλί"),
             blushIntensity: 0.45, shadow: shadow("Bronze"), shadowIntensity: 0.5, shimmer: 0.6, liner: liner("Καφέ"),
             wing: 0.5, smooth: 0.3, glow: 0.6, contour: 0.3),
        Look(name: "Berry", lip: lip("Berry"), lipIntensity: 0.9, blush: blush("Berry"), blushIntensity: 0.35,
             shadow: shadow("Δαμασκηνί"), shadowIntensity: 0.6, shimmer: 0.4, liner: liner("Δαμασκηνί"), wing: 0.9,
             smooth: 0.45, glow: 0.35, contour: 0.3),
    ]
}

// MARK: - Shade properties

extension Shade {
    /// Hue in degrees (red = 0), saturation and brightness.
    var hsv: (h: Float, s: Float, v: Float) {
        let c = rgb
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        guard d > 1e-5 else { return (0, 0, mx) }
        var h: Float
        if mx == c.x { h = (c.y - c.z) / d } else if mx == c.y { h = 2 + (c.z - c.x) / d } else { h = 4 + (c.x - c.y) / d }
        h *= 60
        if h < 0 { h += 360 }
        return (h, d / mx, mx)
    }

    /// -1 = cool (leans blue or pink) ... +1 = warm (leans orange or gold); greys are 0.
    /// Reds, pinks and browns are judged by which side of pure red they fall on.
    var warmth: Float {
        let (h, s, _) = hsv
        let signed = h > 180 ? h - 360 : h
        let base = abs(signed) <= 60 ? min(max(signed / 25, -1), 1) : cos((h - 40) * .pi / 180)
        return base * min(1, s / 0.3)
    }

    /// 0 = soft and light ... 1 = deep or vivid.
    var strength: Float {
        let c = rgb
        let y = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
        return max(1 - y, 0.6 * (1 - y) + 0.4 * hsv.s)
    }
}

// MARK: - Measurements and recommendation

/// What was measured on this face.
struct FaceProfile: Equatable {
    var length: Float       // face length for its width, against the average face (1 = average)
    var jaw: Float          // jaw width for the cheekbone width, against the average face
    var eyeGap: Float       // gap between the eyes for their width, against the average face
    var eyeTilt: Float      // tilt of the eyes against the average face, degrees (+ = outer corner higher)
    var contrast: ContrastLevel
    var undertone: Undertone
}

struct Tip: Identifiable, Equatable {
    var icon: String
    var text: String
    var id: String { text }
}

/// What suits this face: shades ranked for her undertone and contrast, placement for her face shape
/// and eyes, and two complete looks.
struct Recommendation: Equatable {
    var shape: FaceShape
    var lengthPct: Int
    var jawPct: Int
    var contrast: ContrastLevel
    var undertone: Undertone
    var eyeSpacing: EyeSpacing
    var eyeTilt: EyeTilt
    var blush: BlushPlacement
    var lips: [Shade]           // best first
    var blushes: [Shade]
    var shadows: [Shade]
    var liners: [Shade]
    var tips: [Tip]
    var day: Look
    var night: Look

    /// The shades marked as "suits you" in each palette.
    var starred: Set<Shade> { Set(lips.prefix(3) + blushes.prefix(2) + shadows.prefix(3) + liners.prefix(2)) }
}

enum Advisor {
    enum Product { case lips, blush, shadow }
    enum Occasion { case day, night }

    /// How deep or vivid a product should be for this contrast level and occasion (see `Shade.strength`).
    static func targetStrength(_ p: Product, _ c: ContrastLevel, _ o: Occasion) -> Float {
        switch (p, c, o) {
        case (.lips, .low, .day): return 0.42
        case (.lips, .low, .night): return 0.58
        case (.lips, .medium, .day): return 0.50
        case (.lips, .medium, .night): return 0.70
        case (.lips, .high, .day): return 0.55
        case (.lips, .high, .night): return 0.80
        case (.blush, .low, .day): return 0.33
        case (.blush, .low, .night): return 0.38
        case (.blush, .medium, .day): return 0.42
        case (.blush, .medium, .night): return 0.47
        case (.blush, .high, .day): return 0.50
        case (.blush, .high, .night): return 0.55
        case (.shadow, .low, .day): return 0.30
        case (.shadow, .low, .night): return 0.50
        case (.shadow, .medium, .day): return 0.45
        case (.shadow, .medium, .night): return 0.60
        case (.shadow, .high, .day): return 0.50
        case (.shadow, .high, .night): return 0.75
        }
    }

    /// 0...1: how well a shade suits this undertone and contrast, for an occasion.
    static func score(_ s: Shade, _ p: Product, undertone: Undertone, contrast: ContrastLevel, _ o: Occasion) -> Float {
        let w = s.warmth
        var penalty: Float
        switch undertone {
        case .cool: penalty = 0.5 * max(0, w + 0.35)      // anything clearly cool is equally good
        case .warm: penalty = 0.5 * max(0, 0.35 - w)
        case .neutral: penalty = 0.25 * abs(w)
        }
        // Greens and blues are statement colours: fine, but not the first thing to suggest.
        let (h, sat, _) = s.hsv
        if h > 90, h < 260, sat > 0.3 { penalty += 0.08 }
        return max(0, 1 - penalty - 1.5 * abs(s.strength - targetStrength(p, contrast, o)))
    }

    private static func ranked(_ list: [Shade], _ p: Product, _ u: Undertone, _ c: ContrastLevel, _ o: Occasion) -> [Shade] {
        list.sorted { score($0, p, undertone: u, contrast: c, o) > score($1, p, undertone: u, contrast: c, o) }
    }

    /// Best first, judged by the better of the day and night scores.
    private static func overall(_ list: [Shade], _ p: Product, _ u: Undertone, _ c: ContrastLevel) -> [Shade] {
        func best(_ s: Shade) -> Float {
            max(score(s, p, undertone: u, contrast: c, .day), score(s, p, undertone: u, contrast: c, .night))
        }
        // The day pick and the night pick come first, then the rest by score.
        let day = ranked(list, p, u, c, .day)[0], night = ranked(list, p, u, c, .night)[0]
        var out = [day]
        if night != day { out.append(night) }
        out += list.filter { !out.contains($0) }.sorted { best($0) > best($1) }
        return out
    }

    private static func liners(_ u: Undertone, _ c: ContrastLevel) -> (day: Shade?, night: Shade, ranked: [Shade]) {
        func find(_ n: String) -> Shade { Palette.liner.first { $0.name == n } ?? Palette.liner[0] }
        let black = find("Μαύρο"), brown = find("Καφέ"), navy = find("Navy"), plum = find("Δαμασκηνί")
        let soft = u == .cool ? plum : brown
        let alt = u == .warm ? plum : navy
        func all(_ first: [Shade]) -> [Shade] { first + [black, brown, navy, plum].filter { !first.contains($0) } }
        switch c {
        case .low: return (nil, soft, all([soft, alt]))
        case .medium: return (soft, black, all([soft, black, alt]))
        case .high: return (soft, black, all([black, soft, alt]))
        }
    }

    /// How well a ready-made look suits her (0...1): the average over its products.
    static func fit(_ look: Look, undertone: Undertone, contrast: ContrastLevel) -> Float {
        var s: [Float] = []
        func best(_ sh: Shade, _ p: Product) -> Float {
            max(score(sh, p, undertone: undertone, contrast: contrast, .day),
                score(sh, p, undertone: undertone, contrast: contrast, .night))
        }
        if let l = look.lip { s.append(best(l, .lips)) }
        if let b = look.blush { s.append(best(b, .blush)) }
        if let e = look.shadow { s.append(best(e, .shadow)) }
        return s.isEmpty ? 0 : s.reduce(0, +) / Float(s.count)
    }

    static func recommend(_ p: FaceProfile) -> Recommendation {
        let shape: FaceShape
        if p.jaw > 1.035 { shape = .square }
        else if p.jaw < 0.965 { shape = .heart }
        else if p.length > 1.035 { shape = .long }
        else if p.length < 0.965 { shape = .round }
        else { shape = .oval }
        let spacing: EyeSpacing = p.eyeGap > 1.07 ? .wide : (p.eyeGap < 0.93 ? .close : .average)
        let tilt: EyeTilt = p.eyeTilt > 2.5 ? .up : (p.eyeTilt < -2.5 ? .down : .straight)
        let u = p.undertone, c = p.contrast

        // ---- Placement for the face shape
        let blush: BlushPlacement
        let blushTip: String, browTip: String, contourTip: String
        var contour = 0.2
        switch shape {
        case .oval:
            blush = .standard
            blushTip = "Ρουζ στα μήλα, σβησμένο προς τους κροτάφους."
            browTip = "Απαλή καμάρα· κράτα το φυσικό σου σχήμα."
            contourTip = "Ελαφρύ contour κάτω από τα ζυγωματικά αρκεί· οι αναλογίες σου είναι ισορροπημένες."
        case .round:
            blush = BlushPlacement(out: 1.30, down: 0.42, rx: 0.023, ry: 0.011, tilt: 0.60)
            blushTip = "Ρουζ λίγο πιο έξω και διαγώνια προς τους κροτάφους, όχι πάνω στα μήλα: λεπταίνει το πρόσωπο."
            browTip = "Πιο ψηλή, γωνιώδης καμάρα μακραίνει το πρόσωπο."
            contourTip = "Contour κάτω από τα ζυγωματικά, διαγώνια προς το στόμα, για να δώσεις γωνίες."
            contour = 0.35
        case .long:
            blush = BlushPlacement(out: 1.15, down: 0.50, rx: 0.024, ry: 0.013, tilt: 0.05)
            blushTip = "Ρουζ οριζόντια πάνω στα μήλα, χωρίς να ανεβαίνει στους κροτάφους: δίνει πλάτος."
            browTip = "Πιο ίσια, οριζόντια φρύδια κονταίνουν οπτικά το πρόσωπο."
            contourTip = "Λίγο bronzer στη γραμμή των μαλλιών και κάτω από το πιγούνι κονταίνει το πρόσωπο· στα μάγουλα ελάχιστο."
            contour = 0.15
        case .square:
            blush = BlushPlacement(out: 1.18, down: 0.46, rx: 0.018, ry: 0.016, tilt: 0.20)
            blushTip = "Ρουζ στρογγυλό πάνω στα μήλα, για να μαλακώνει τις γωνίες."
            browTip = "Στρογγυλεμένη καμάρα μαλακώνει το σαγόνι."
            contourTip = "Contour στις γωνίες του σαγονιού και στους κροτάφους μαλακώνει το περίγραμμα."
            contour = 0.3
        case .heart:
            blush = BlushPlacement(out: 1.28, down: 0.50, rx: 0.022, ry: 0.012, tilt: 0.45)
            blushTip = "Ρουζ κάτω από το ζυγωματικό, σε απαλή καμπύλη προς τον κρόταφο."
            browTip = "Απαλή, χαμηλή καμάρα· όχι πολύ λεπτά φρύδια."
            contourTip = "Λίγο contour στους κροτάφους και highlighter στο πιγούνι ισορροπούν το στενό σαγόνι."
        }

        // ---- Shades for the undertone and the contrast
        let lips = overall(Palette.lips, .lips, u, c)
        let blushes = overall(Palette.blush, .blush, u, c)
        let shadows = overall(Palette.eyeshadow, .shadow, u, c)
        let liner = liners(u, c)

        let toneTip: String
        switch u {
        case .cool: toneTip = "Ψυχρός υπότονος: σου πάνε ροζ, berry, μοβ και κόκκινα που γέρνουν στο μπλε. Στα κοσμήματα, ασημί."
        case .warm: toneTip = "Θερμός υπότονος: σου πάνε κοραλί, ροδακινί, τούβλο, μπρονζέ και χρυσαφί."
        case .neutral: toneTip = "Ουδέτερος υπότονος: σηκώνεις και ζεστά και ψυχρά χρώματα· rosewood και nude είναι σίγουρη επιλογή."
        }
        let contrastTip: String
        switch c {
        case .low: contrastTip = "Χαμηλή αντίθεση (φρύδια και δέρμα σε κοντινό τόνο): σου πάνε απαλά, τονικά χρώματα· τα πολύ σκούρα σε «σκεπάζουν»."
        case .medium: contrastTip = "Μεσαία αντίθεση: μεσαίες εντάσεις τη μέρα, ένα έντονο σημείο (χείλη ή μάτια) το βράδυ."
        case .high: contrastTip = "Υψηλή αντίθεση (σκούρα φρύδια σε πιο ανοιχτό δέρμα): σηκώνεις έντονα, καθαρά χρώματα."
        }
        var tips = [Tip(icon: "thermometer.medium", text: toneTip), Tip(icon: "circle.lefthalf.filled", text: contrastTip),
                    Tip(icon: "face.smiling", text: blushTip), Tip(icon: "eyebrow", text: browTip),
                    Tip(icon: "sun.max", text: contourTip)]
        var wingShift = 0.0
        switch spacing {
        case .close:
            tips.append(Tip(icon: "eye", text: "Μάτια κοντά μεταξύ τους: ανοιχτή σκιά στην εσωτερική γωνία, σκούρο χρώμα και eyeliner μόνο στο εξωτερικό μισό, με φτερό προς τα έξω."))
            wingShift += 0.2
        case .wide:
            tips.append(Tip(icon: "eye", text: "Μάτια μακριά μεταξύ τους: σκούρα σκιά και eyeliner από την εσωτερική γωνία, με κοντό φτερό."))
            wingShift -= 0.2
        case .average:
            break
        }
        switch tilt {
        case .down:
            tips.append(Tip(icon: "arrow.up.right", text: "Η εξωτερική γωνία των ματιών πέφτει ελαφρά: φτερό που ανεβαίνει προς τον κρόταφο σηκώνει το βλέμμα."))
            wingShift += 0.2
        case .up:
            tips.append(Tip(icon: "arrow.right", text: "Η εξωτερική γωνία των ματιών ανεβαίνει: λεπτή γραμμή που ακολουθεί το βλέφαρο, με φτερό στην ίδια κλίση."))
        case .straight:
            break
        }

        // ---- Two complete looks
        let dayLip = ranked(Palette.lips, .lips, u, c, .day)[0], nightLip = ranked(Palette.lips, .lips, u, c, .night)[0]
        let level: Double = c == .low ? 0 : (c == .medium ? 1 : 2)
        let day = Look(name: "Καθημερινό", lip: dayLip, lipFinish: .satin, lipIntensity: 0.7 + 0.05 * level,
                       blush: ranked(Palette.blush, .blush, u, c, .day)[0], blushIntensity: 0.35 + 0.025 * level,
                       shadow: ranked(Palette.eyeshadow, .shadow, u, c, .day)[0], shadowIntensity: 0.4 + 0.05 * level,
                       shimmer: 0.3, liner: liner.day, wing: max(0.2, 0.4 + 0.1 * level + wingShift),
                       smooth: 0.35, glow: 0.25, contour: 0)
        let night = Look(name: "Βραδινό", lip: nightLip, lipFinish: nightLip.strength > 0.7 ? .matte : .satin,
                         lipIntensity: 0.8 + 0.05 * level,
                         blush: ranked(Palette.blush, .blush, u, c, .night)[0], blushIntensity: 0.4,
                         shadow: ranked(Palette.eyeshadow, .shadow, u, c, .night)[0], shadowIntensity: 0.55 + 0.05 * level,
                         shimmer: 0.5, liner: liner.night, wing: max(0.3, 0.8 + 0.2 * level + wingShift),
                         smooth: 0.45, glow: 0.4, contour: contour)

        return Recommendation(shape: shape, lengthPct: Int(((p.length - 1) * 100).rounded()),
                              jawPct: Int(((p.jaw - 1) * 100).rounded()), contrast: c, undertone: u,
                              eyeSpacing: spacing, eyeTilt: tilt, blush: blush,
                              lips: lips, blushes: blushes, shadows: shadows, liners: liner.ranked,
                              tips: tips, day: day, night: night)
    }
}

/// Measures the face on the live ARKit mesh, which is fitted to the person's own head shape.
/// The measurements are 3D distances between mesh points, so the head pose does not matter;
/// only frames with a relaxed, closed mouth are used. They are compared with the same
/// measurements on ARKit's average face.
final class FaceMeasure {
    static let target = 40
    private let geometry: FaceGeometry
    private let baseShape: SIMD2<Float>
    private let baseEyes: SIMD2<Float>
    private var shapeSum = SIMD2<Float>(repeating: 0)
    private var eyeSum = SIMD2<Float>(repeating: 0)
    private(set) var count = 0

    /// Once measured: length, jaw and eye-gap ratios against the average face (1 = average),
    /// and the eye tilt against the average face in degrees.
    private(set) var result: (length: Float, jaw: Float, eyeGap: Float, eyeTilt: Float)?

    var progress: Float { Float(min(count, Self.target)) / Float(Self.target) }

    init(geometry: FaceGeometry) {
        self.geometry = geometry
        baseShape = geometry.shapeRatios(geometry.neutral)
        baseEyes = geometry.eyeRatios(geometry.neutral)
    }

    func reset() {
        shapeSum = .zero
        eyeSum = .zero
        count = 0
        result = nil
    }

    func add(_ live: [SIMD3<Float>]) {
        guard result == nil else { return }
        shapeSum += geometry.shapeRatios(live)
        eyeSum += geometry.eyeRatios(live)
        count += 1
        if count >= Self.target {
            let s = shapeSum / Float(count) / baseShape, e = eyeSum / Float(count)
            result = (s.x, s.y, e.x / baseEyes.x, (e.y - baseEyes.y) * 180 / .pi)
        }
    }
}
