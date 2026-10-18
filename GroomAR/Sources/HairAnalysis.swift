import Foundation
import simd

/// Layout of the counters the shaders write every frame (UInt32 each). Must match Shaders.metal.
enum Counters {
    static let zones = 0                 // (pixels, hair pixels) x 8 zones
    static let hist = 16                 // histogram of the hair score on the clean-skin patch
    static let histBins = 64
    static let histStep: Float = 0.002
    static let ref = 80                  // patch pixels, sum Y, sum Cb, sum Cr (8 bit)
    static let sym = 96                  // side (2) x bin (32) x (pixels, sum density, sum darkness)
    static let symBins = 32
    static let symBinSize: Float = 0.001 // metres of S per bin, starting at -16 mm
    static let symDensityScale: Float = 0.128
    static let count = 288
}

/// Where the real edge of the beard is on each cheek, against the guide (mm, + = above the guide).
struct SymmetryStatus: Equatable {
    var left: Double     // the person's own left
    var right: Double
    var delta: Double { left - right }
    var even: Bool { abs(delta) < 1.5 }
}

/// Turns the per-frame counters into what the app shows and what the detector uses:
///  - the person's own clean-skin level (noise + skin texture) -> detector thresholds, and skin colour;
///  - the real beard edge on each cheek -> symmetry.
final class HairAnalysis {
    /// Detector thresholds for the shader: speck lo, speck hi, density lo, density hi.
    private(set) var det = SIMD4<Float>(0.030, 0.070, 0.020, 0.036)
    /// Learned skin colour (linear rgb), w = 1 once it can be used.
    private(set) var skin = SIMD4<Float>(repeating: 0)
    /// 0...1 while the skin is being learned.
    private(set) var learned: Float = 0

    private var p90: Float = 0
    private var mean: Float = 0
    private var ycc = SIMD3<Float>(repeating: 0)
    private var frames = 0
    private var sym = [Float](repeating: 0, count: 2 * Counters.symBins * 3)

    // MARK: - Skin

    /// Feeds one frame of the clean-skin patch (upper cheeks, where no beard grows).
    func learnSkin(_ c: [UInt32]) {
        let n = Float(c[Counters.ref])
        guard n >= 200 else { return }
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
        let m = sum / n
        let colour = SIMD3(Float(c[Counters.ref + 1]), Float(c[Counters.ref + 2]), Float(c[Counters.ref + 3])) / (n * 255)

        // Quick at first, then slow: follows changes of light without flickering.
        let a: Float = frames < 20 ? 1 / Float(frames + 1) : 0.05
        p90 += (q90 - p90) * a
        mean += (m - mean) * a
        ycc += (colour - ycc) * a
        frames += 1
        learned = min(1, Float(frames) / 20)
        guard frames >= 8 else { return }

        // A single hair has to stand out clearly from this person's own skin texture and from the
        // camera noise in the current light; an area of hair has to be clearly busier than clean skin.
        let lo = min(max(1.5 * p90 + 0.004, 0.018), 0.090)
        let dLo = min(max(2.2 * mean + 0.004, 0.010), 0.060)
        det = SIMD4(lo, 2 * lo + 0.010, dLo, 1.8 * dLo)
        skin = SIMD4(Self.linearRGB(y: ycc.x, cb: ycc.y, cr: ycc.z), 1)
    }

    private static func linearRGB(y: Float, cb: Float, cr: Float) -> SIMD3<Float> {
        let r = y + 1.4020 * (cr - 0.5)
        let g = y - 0.3441 * (cb - 0.5) - 0.7141 * (cr - 0.5)
        let b = y + 1.7720 * (cb - 0.5)
        func lin(_ v: Float) -> Float {
            let c = min(max(v, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return SIMD3(lin(r), lin(g), lin(b))
    }

    // MARK: - Symmetry

    /// Adds one frontal frame of the two hair profiles (older frames fade out).
    func addSymmetry(_ c: [UInt32]) {
        for i in 0..<sym.count { sym[i] = sym[i] * 0.9 + Float(c[Counters.sym + i]) }
    }

    /// Lets the profiles fade while the face is turned away or the guide is changing.
    func fadeSymmetry() {
        for i in 0..<sym.count { sym[i] *= 0.9 }
    }

    /// The real beard edge on both cheeks, or nil when no clear edge can be seen on one of them.
    func symmetry() -> SymmetryStatus? {
        guard let r = edge(side: 0), let l = edge(side: 1) else { return nil }   // +x side = the person's left
        func mm(_ v: Float) -> Double { (Double(v) * 1000 * 2).rounded() / 2 }
        return SymmetryStatus(left: mm(l), right: mm(r))
    }

    /// Signed distance (metres) from the guide to where the hair really stops on one side.
    private func edge(side: Int) -> Float? {
        let nb = Counters.symBins
        var n = [Float](repeating: 0, count: nb)
        var dens = [Float](repeating: 0, count: nb)
        var dark = [Float](repeating: 0, count: nb)
        var valid = 0
        for k in 0..<nb {
            let i = (side * nb + k) * 3
            n[k] = sym[i]
            guard n[k] > 300 else { continue }
            valid += 1
            dens[k] = sym[i + 1] / n[k] / 255 * Counters.symDensityScale
            dark[k] = sym[i + 2] / n[k] / 255
        }
        guard valid >= 20 else { return nil }
        // Prefer hair texture (works for any hair colour); fall back to darkness.
        return findStep(dens, n, minRatio: 1.7, minGap: 0.004) ?? findStep(dark, n, minRatio: 1.0, minGap: 0.12)
    }

    /// Best single step (hair below, clean above) in a profile over the bins; nil without a clear one.
    private func findStep(_ raw: [Float], _ n: [Float], minRatio: Float, minGap: Float) -> Float? {
        let nb = raw.count
        // Fill bins without pixels from their neighbours, then smooth lightly.
        var p = raw
        var last: Float?
        for k in 0..<nb { if n[k] > 300 { last = p[k] } else if let last { p[k] = last } }
        last = nil
        for k in stride(from: nb - 1, through: 0, by: -1) { if n[k] > 300 { last = p[k] } else if let last { p[k] = last } }
        var s = p
        for k in 1..<(nb - 1) { s[k] = 0.25 * p[k - 1] + 0.5 * p[k] + 0.25 * p[k + 1] }

        let sorted = s.sorted()
        let q = nb / 4
        let lo = sorted[0..<q].reduce(0, +) / Float(q)
        let hi = sorted[(nb - q)...].reduce(0, +) / Float(q)
        guard hi > minRatio * lo + minGap else { return nil }
        let t = 0.5 * (hi + lo)

        // Split point that best separates "hair" bins (below it) from "clean" bins (above it).
        var best = 0, bestScore = -Float.greatestFiniteMagnitude
        var below: Float = 0
        let total = s.reduce(0) { $0 + ($1 - t) }
        for k in 1..<nb {
            below += s[k - 1] - t
            let score = below - (total - below)
            if score > bestScore { bestScore = score; best = k }
        }
        guard best >= 3, best <= nb - 3, bestScore > 0 else { return nil }
        // Bin centres are at -15.5 mm + k; interpolate the crossing between the two bins at the split.
        let a = s[best - 1], b = s[best]
        let f: Float = (a > t && b < t) ? (a - t) / (a - b) : 0.5
        return (Float(best - 1) + 0.5 + f) * Counters.symBinSize - 0.016
    }
}
