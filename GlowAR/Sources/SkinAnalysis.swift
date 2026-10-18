import Foundation
import simd

/// Layout of the counters the shaders write every frame (UInt32 each). Must match Shaders.metal.
enum Counters {
    static let zones = 0                 // (pixels, hair pixels) x 8 zones; 3 = between the brows, 4 = around them
    static let hist = 16                 // histogram of the hair score on the clean-skin patch
    static let histBins = 64
    static let histStep: Float = 0.002
    static let ref = 80                  // patch pixels, sums of luma, Cb, Cr (8 bit)
    static let browHist = 96             // histogram of luma over the brow area
    static let browBins = 32
    static let count = 128
}

/// How dark the brows are against the skin. Independent of exposure, because it is a ratio.
enum ContrastLevel: String {
    case low, medium, high

    var title: String {
        switch self {
        case .low: return "Χαμηλή"
        case .medium: return "Μεσαία"
        case .high: return "Υψηλή"
        }
    }
}

/// Whether the skin leans pink (cool) or golden (warm).
enum Undertone: String, CaseIterable, Identifiable {
    case cool, neutral, warm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cool: return "Ψυχρός"
        case .neutral: return "Ουδέτερος"
        case .warm: return "Θερμός"
        }
    }

    /// From the hue of the skin colour (degrees; red = 0, yellow = 60).
    static func from(hue: Float) -> Undertone {
        hue < 16 ? .cool : (hue > 23 ? .warm : .neutral)
    }
}

/// Turns the per-frame counters into the hair detector thresholds (from the person's own clean
/// skin in the current light), the contrast between her brows and her skin, and her skin's hue.
final class SkinAnalysis {
    /// Detector thresholds for the shader: speck lo, speck hi, density lo, density hi.
    private(set) var det = SIMD4<Float>(0.030, 0.070, 0.020, 0.036)
    /// Brow luminance / skin luminance (linear light), once measured.
    private(set) var browRatio: Float?
    /// Hue of the clean cheek skin in degrees, once measured.
    private(set) var skinHue: Float?

    private var p90: Float = 0
    private var mean: Float = 0
    private var ratio: Float = 0
    private var hue: Float = 0
    private var frames = 0
    private var ratioFrames = 0
    private var hueFrames = 0
    private var calls = 0

    static let framesNeeded = 30

    /// After this many frames without a usable reading (brows covered, light too harsh), the middle
    /// value is used instead of waiting for ever.
    static let giveUpAfter = 240

    var contrast: ContrastLevel? {
        guard let r = browRatio else { return calls >= Self.giveUpAfter ? .medium : nil }
        return r < 0.22 ? .high : (r < 0.45 ? .medium : .low)
    }

    var undertone: Undertone? {
        skinHue.map(Undertone.from(hue:)) ?? (calls >= Self.giveUpAfter ? .neutral : nil)
    }

    /// 0...1: how much of the contrast and undertone measurement is done.
    var progress: Float {
        max(Float(min(ratioFrames, hueFrames)) / Float(Self.framesNeeded), Float(calls) / Float(Self.giveUpAfter))
    }

    /// Forgets the contrast and the undertone, to measure them again (new light, new person).
    func resetMeasurements() {
        browRatio = nil
        skinHue = nil
        ratioFrames = 0
        hueFrames = 0
        calls = 0
    }

    func learn(_ c: [UInt32]) {
        let n = Float(c[Counters.ref])
        guard n >= 200 else { return }
        calls += 1
        var acc: Float = 0, sum: Float = 0, q90: Float = 0
        var found = false
        for b in 0..<Counters.histBins {
            let h = Float(c[Counters.hist + b])
            if !found, acc + h >= 0.9 * n {
                q90 = (Float(b) + (h > 0 ? (0.9 * n - acc) / h : 0)) * Counters.histStep
                found = true
            }
            acc += h
            sum += h * (Float(b) + 0.5) * Counters.histStep
        }
        let a: Float = frames < 20 ? 1 / Float(frames + 1) : 0.05
        p90 += (q90 - p90) * a
        mean += (sum / n - mean) * a
        frames += 1
        if frames >= 8 {
            let lo = min(max(1.5 * p90 + 0.004, 0.018), 0.090)
            let dLo = min(max(2.2 * mean + 0.004, 0.010), 0.060)
            det = SIMD4(lo, 2 * lo + 0.010, dLo, 1.8 * dLo)
        }

        // Skin hue, from the mean colour of the clean patch. Skipped when the patch is blown out or too dark.
        let skinY = Float(c[Counters.ref + 1]) / (n * 255)
        let cb = Float(c[Counters.ref + 2]) / (n * 255) - 0.5, cr = Float(c[Counters.ref + 3]) / (n * 255) - 0.5
        let rgb = SIMD3(skinY + 1.402 * cr, skinY - 0.3441 * cb - 0.7141 * cr, skinY + 1.772 * cb)
        if skinY > 0.15, skinY < 0.92, rgb.x > rgb.y, rgb.y > rgb.z, rgb.x - rgb.z > 0.03 {
            let h = 60 * (rgb.y - rgb.z) / (rgb.x - rgb.z)
            let ha: Float = hueFrames < Self.framesNeeded ? 1 / Float(hueFrames + 1) : 0.03
            hue += (h - hue) * ha
            hueFrames += 1
            if hueFrames >= Self.framesNeeded { skinHue = hue }
        }

        // Brow darkness: the darkest tenth of the brow area (the hairs) against the mean skin.
        let total = (0..<Counters.browBins).reduce(Float(0)) { $0 + Float(c[Counters.browHist + $1]) }
        guard total >= 300, skinY > 0.05 else { return }
        var seen: Float = 0
        var dark: Float = 0
        for b in 0..<Counters.browBins {
            let h = Float(c[Counters.browHist + b])
            if seen + h >= 0.1 * total {
                dark = (Float(b) + (h > 0 ? (0.1 * total - seen) / h : 0)) / Float(Counters.browBins)
                break
            }
            seen += h
        }
        let r = pow(min(dark / skinY, 1), 2.2)   // gamma-encoded ratio -> linear light
        let ra: Float = ratioFrames < Self.framesNeeded ? 1 / Float(ratioFrames + 1) : 0.03
        ratio += (r - ratio) * ra
        ratioFrames += 1
        if ratioFrames >= Self.framesNeeded { browRatio = ratio }
    }
}
