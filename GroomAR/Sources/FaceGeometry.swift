import ARKit
import simd

/// A point glued to the face mesh: a triangle plus barycentric weights.
struct SurfaceAnchor {
    var a: Int, b: Int, c: Int
    var bary: SIMD3<Float>

    func position(_ v: [SIMD3<Float>]) -> SIMD3<Float> {
        v[a] * bary.x + v[b] * bary.y + v[c] * bary.z
    }
}

/// Per-vertex data for the mask pass. Meaning depends on the mode:
///  beard: a0 = (S: signed distance to the style edge, <0 = keep beard; lip; isNeck; growth zone)
///         a1 = (hair coord x, hair coord y, 0, 0)
///  brows: a0 = (start field, arch field, end field, 1)  — each = signed distance to that line, >0 towards the nose
///         a1 = (x, y, zone between the brows, 0)
struct VertexAttributes {
    var a0: [SIMD4<Float>]
    var a1: [SIMD4<Float>]
    /// Beard only: where the two sides are compared for symmetry (|x| min, |x| max, y min, y max).
    var sym = SIMD4<Float>(repeating: 0)
}

/// Face landmarks found from the ARKit mesh topology (its open boundaries are the face outline,
/// the eye openings and the mouth opening), plus a "neck skirt": extra rings of geometry hanging
/// under the jaw so the neckline can be drawn on the neck and still follow the head.
final class FaceGeometry {
    static let rings = 5
    static let ringStep: Float = 0.013

    let neutral: [SIMD3<Float>]
    let faceVertexCount: Int
    let indices: [UInt16]          // face triangles + neck skirt triangles

    let tris: [Int]
    let triCount: Int
    let eyeInnerIdx: [Int]         // vertex indices of the eye corners, same order as eyeInner/eyeOuter
    let eyeOuterIdx: [Int]
    private let cheekIdx: [[Int]]  // outline vertices at cheekbone height, per side
    private let jawIdx: [[Int]]    // outline vertices at the jaw corners, per side
    private let chinIdx: Int
    private let contour: [SIMD3<Float>]
    private let skirtRun: [Int]
    private let skirtDirs: [SIMD3<Float>]
    private let maxJawX: Float

    let eyeInner: [SIMD3<Float>]   // index 0 = -x side, 1 = +x side
    let eyeOuter: [SIMD3<Float>]
    let eyeCenter: [SIMD3<Float>]
    let mouthCorner: [SIMD3<Float>]
    let mouthCenter: SIMD3<Float>
    let mouthHalfWidth: Float
    let chin: SIMD3<Float>

    var eyeY: Float { 0.5 * (eyeCenter[0].y + eyeCenter[1].y) }
    var eyeToMouth: Float { eyeY - mouthCenter.y }
    var totalVertexCount: Int { faceVertexCount + skirtRun.count * Self.rings }

    init?(_ geo: ARFaceGeometry) {
        let v = geo.vertices
        neutral = v
        faceVertexCount = v.count
        tris = geo.triangleIndices.map { Int(UInt16(bitPattern: $0)) }
        triCount = geo.triangleCount

        func key(_ a: Int, _ b: Int) -> Int { a < b ? (a << 16) | b : (b << 16) | a }
        var edgeCount: [Int: Int] = [:]
        for t in 0..<triCount {
            let a = tris[3 * t], b = tris[3 * t + 1], c = tris[3 * t + 2]
            for (p, q) in [(a, b), (b, c), (c, a)] { edgeCount[key(p, q), default: 0] += 1 }
        }
        var adj: [Int: [Int]] = [:]
        for (k, cnt) in edgeCount where cnt == 1 {
            let a = k >> 16, b = k & 0xFFFF
            adj[a, default: []].append(b)
            adj[b, default: []].append(a)
        }
        var visited = Set<Int>()
        var loops: [[Int]] = []
        for start in adj.keys.sorted() where !visited.contains(start) {
            var loop = [start]
            visited.insert(start)
            var prev = -1, cur = start
            while let next = adj[cur]?.first(where: { $0 != prev && !visited.contains($0) }) {
                loop.append(next)
                visited.insert(next)
                prev = cur
                cur = next
            }
            if loop.count >= 6 { loops.append(loop) }
        }
        guard loops.count >= 4 else { return nil }

        func width(_ l: [Int]) -> Float {
            let xs = l.map { v[$0].x }
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        func centroid(_ l: [Int]) -> SIMD3<Float> { l.reduce(.zero) { $0 + v[$1] } / Float(l.count) }

        let byWidth = loops.sorted { width($0) > width($1) }
        let outer = byWidth[0]
        let inner = Array(byWidth.dropFirst().prefix(3)).sorted { centroid($0).y < centroid($1).y }
        guard inner.count == 3 else { return nil }
        let mouth = inner[0]
        let eyes = inner[1...].sorted { centroid($0).x < centroid($1).x }

        contour = outer.map { v[$0] }
        var ei: [Int] = [], eo: [Int] = [], ec: [SIMD3<Float>] = []
        for eye in eyes {
            let c = centroid(eye)
            let minX = eye.min { v[$0].x < v[$1].x }!, maxX = eye.max { v[$0].x < v[$1].x }!
            if c.x < 0 { ei.append(maxX); eo.append(minX) } else { ei.append(minX); eo.append(maxX) }
            ec.append(c)
        }
        eyeInnerIdx = ei
        eyeOuterIdx = eo
        eyeInner = ei.map { v[$0] }
        eyeOuter = eo.map { v[$0] }
        eyeCenter = ec

        let mp = mouth.map { v[$0] }
        let mMin = mp.min { $0.x < $1.x }!, mMax = mp.max { $0.x < $1.x }!
        mouthCorner = [mMin, mMax]
        let mc = centroid(mouth)
        mouthCenter = mc
        mouthHalfWidth = 0.5 * (mMax.x - mMin.x)
        chin = contour.filter { abs($0.x) < 0.02 }.min { $0.y < $1.y } ?? contour.min { $0.y < $1.y }!

        // Outline points used to measure the face shape (same vertices on the live mesh).
        let eyY = 0.5 * (ec[0].y + ec[1].y)
        let e2m = eyY - mc.y
        func outline(_ y: Float, _ side: Float) -> [Int] {
            Array(outer.filter { v[$0].x * side > 0.02 }.sorted { abs(v[$0].y - y) < abs(v[$1].y - y) }.prefix(2))
        }
        cheekIdx = [outline(eyY - 0.15 * e2m, -1), outline(eyY - 0.15 * e2m, 1)]
        jawIdx = [outline(mc.y - 0.05 * e2m, -1), outline(mc.y - 0.05 * e2m, 1)]
        chinIdx = outer.filter { abs(v[$0].x) < 0.02 }.min { v[$0].y < v[$1].y } ?? outer.min { v[$0].y < v[$1].y }!
        guard cheekIdx.allSatisfy({ !$0.isEmpty }), jawIdx.allSatisfy({ !$0.isEmpty }) else { return nil }

        // Neck skirt: the run of outline vertices below the mouth, ordered side to side.
        let below = outer.map { v[$0].y < mc.y + 0.004 }
        guard let startIdx = below.firstIndex(of: false) else { return nil }
        var run: [Int] = []
        for k in 0..<outer.count {
            let i = (startIdx + k) % outer.count
            if below[i] { run.append(outer[i]) } else if !run.isEmpty { break }
        }
        guard run.count >= 4 else { return nil }
        if v[run.first!].x > v[run.last!].x { run.reverse() }
        skirtRun = run
        let mx = run.map { abs(v[$0].x) }.max() ?? 0.06
        maxJawX = mx
        skirtDirs = run.map { i in
            let t = min(abs(v[i].x) / max(mx, 1e-3), 1)
            // Under the chin the neck runs backwards; near the ears it runs down.
            let centre = simd_normalize(SIMD3<Float>(0, -0.55, -1.0))
            let side = simd_normalize(SIMD3<Float>(0, -1.0, -0.25))
            return simd_normalize(centre + (side - centre) * (t * t))
        }

        var idx = geo.triangleIndices.map { UInt16(bitPattern: $0) }
        let K = run.count
        func vi(_ r: Int, _ k: Int) -> UInt16 {
            r == 0 ? UInt16(run[k]) : UInt16(v.count + (r - 1) * K + k)
        }
        for r in 1...Self.rings {
            for k in 0..<(K - 1) {
                let v00 = vi(r - 1, k), v01 = vi(r - 1, k + 1), v10 = vi(r, k), v11 = vi(r, k + 1)
                idx += [v00, v10, v01, v01, v10, v11]
            }
        }
        indices = idx
    }

    /// Face vertices followed by the neck skirt rings.
    func positions(_ face: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var out = face
        out.reserveCapacity(totalVertexCount)
        for r in 1...Self.rings {
            let d = Float(r) * Self.ringStep
            for (k, i) in skirtRun.enumerated() { out.append(face[i] + skirtDirs[k] * d) }
        }
        return out
    }

    private func ringOf(_ j: Int) -> Int {
        j < faceVertexCount ? 0 : (j - faceVertexCount) / skirtRun.count + 1
    }

    /// Where the face outline crosses height `y` on one side (side = -1 or +1).
    func sidePoint(y: Float, side: Float) -> SIMD3<Float> {
        var best: SIMD3<Float>?
        let n = contour.count
        for i in 0..<n {
            let p = contour[i], q = contour[(i + 1) % n]
            guard (p.y - y) * (q.y - y) <= 0, p.y != q.y else { continue }
            let t = (y - p.y) / (q.y - p.y)
            let r = p + (q - p) * t
            guard r.x * side > 0 else { continue }
            if best == nil || abs(r.x) > abs(best!.x) { best = r }
        }
        return best ?? contour.max { $0.x * side < $1.x * side }!
    }

    /// Glue a face-plane point (x, y in metres) to the front-most mesh surface under it.
    func anchor(x: Float, y: Float) -> SurfaceAnchor {
        var best: SurfaceAnchor?
        var bestZ = -Float.greatestFiniteMagnitude
        for t in 0..<triCount {
            let ia = tris[3 * t], ib = tris[3 * t + 1], ic = tris[3 * t + 2]
            let a = neutral[ia], b = neutral[ib], c = neutral[ic]
            let v0 = SIMD2(b.x - a.x, b.y - a.y), v1 = SIMD2(c.x - a.x, c.y - a.y), v2 = SIMD2(x - a.x, y - a.y)
            let den = v0.x * v1.y - v1.x * v0.y
            guard abs(den) > 1e-12 else { continue }
            let w1 = (v2.x * v1.y - v1.x * v2.y) / den
            let w2 = (v0.x * v2.y - v2.x * v0.y) / den
            let w0 = 1 - w1 - w2
            guard w0 >= -1e-4, w1 >= -1e-4, w2 >= -1e-4 else { continue }
            let z = a.z * w0 + b.z * w1 + c.z * w2
            if z > bestZ { bestZ = z; best = SurfaceAnchor(a: ia, b: ib, c: ic, bary: SIMD3(w0, w1, w2)) }
        }
        if let best { return best }
        var bi = 0
        var bd = Float.greatestFiniteMagnitude
        for (i, p) in neutral.enumerated() {
            let d = simd_distance_squared(SIMD2(p.x, p.y), SIMD2(x, y))
            if d < bd { bd = d; bi = i }
        }
        return SurfaceAnchor(a: bi, b: bi, c: bi, bary: SIMD3(1, 0, 0))
    }

    /// Clean-skin patch on the upper cheeks, between the eyes and where beard can grow:
    /// |x| min, |x| max, y min, y max. The detector learns the person's skin there.
    var refRegion: SIMD4<Float> {
        SIMD4(0.024, 0.048, eyeY - 0.36 * eyeToMouth, eyeY - 0.17 * eyeToMouth)
    }

    /// Face proportions on any set of face vertices (neutral or live):
    /// x = length (between the eyes to the chin) / cheekbone width, y = jaw width / cheekbone width.
    func shapeRatios(_ v: [SIMD3<Float>]) -> SIMD2<Float> {
        func mid(_ idx: [Int]) -> SIMD3<Float> { idx.reduce(.zero) { $0 + v[$1] } / Float(idx.count) }
        let wCheek = max(simd_distance(mid(cheekIdx[0]), mid(cheekIdx[1])), 1e-4)
        let wJaw = simd_distance(mid(jawIdx[0]), mid(jawIdx[1]))
        let top = 0.5 * (v[eyeInnerIdx[0]] + v[eyeInnerIdx[1]])
        return SIMD2(simd_distance(top, v[chinIdx]) / wCheek, wJaw / wCheek)
    }

    /// Two points on the upper cheeks (skin colour) and two on the brows (hair colour).
    lazy var skinSamples: [SurfaceAnchor] = eyeCenter.map { anchor(x: $0.x * 1.05, y: eyeY - 0.33 * eyeToMouth) }
    lazy var browSamples: [SurfaceAnchor] = eyeCenter.map { anchor(x: $0.x * 1.02, y: $0.y + 0.012) }

    private func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Beard

    func beardAttributes(style: BeardStyle, cheek: Float, neck: Float) -> VertexAttributes {
        let all = positions(neutral)
        let h = eyeToMouth
        let ey = eyeY
        let mc = mouthCenter
        let lipScale = mouthHalfWidth / 0.025

        // Upper edge of the beard (non-goatee styles), as y(|x|): moustache top near the
        // middle, then the cheek line from the moustache corner up to the sideburn.
        let lift: Float
        switch style {
        case .stubble: lift = 0.62
        case .short: lift = 0.42
        case .full: lift = 0.56
        case .goatee: lift = 0
        }
        let cornerY = 0.5 * (mouthCorner[0].y + mouthCorner[1].y)
        let axT = mouthHalfWidth + 0.011
        let yT = cornerY + (lift + cheek * 0.30) * h
        let yS = ey - 0.50 * h + cheek * 0.10 * h
        let axS = 0.5 * (abs(sidePoint(y: yS, side: -1).x) + abs(sidePoint(y: yS, side: 1).x)) - 0.007
        let p0 = SIMD2<Float>(axT, yT), p2 = SIMD2<Float>(axS, yS)
        let ctrl = 0.5 * (p0 + p2) - SIMD2<Float>(0, 0.10 * h)
        let curve: [SIMD2<Float>] = (0...24).map { i -> SIMD2<Float> in
            let t = Float(i) / 24
            return (1 - t) * (1 - t) * p0 + 2 * (1 - t) * t * ctrl + t * t * p2
        }.sorted { $0.x < $1.x }
        let yMoustache = mc.y + 0.33 * h

        func cheekY(_ ax: Float) -> Float {
            if ax >= axS { return yS + (ax - axS) * 1.5 }
            for i in 1..<curve.count where curve[i].x >= ax {
                let a = curve[i - 1], b = curve[i]
                let t = (ax - a.x) / max(b.x - a.x, 1e-6)
                return a.y + (b.y - a.y) * t
            }
            return curve.last!.y
        }
        // Smooth hand-over from the moustache top to the cheek line (no corner notch).
        func topY(_ ax: Float) -> Float {
            let c = cheekY(max(ax, axT))
            return yMoustache + (c - yMoustache) * smooth(axT - 0.018, axT + 0.004, ax)
        }
        // Where beard naturally grows on the face.
        func growthTop(_ ax: Float) -> Float {
            let nose = mc.y + 0.37 * h, cheekbone = ey - 0.38 * h
            return nose + (cheekbone - nose) * smooth(0.014, 0.034, ax) + smooth(0.045, 0.062, ax) * 0.25 * h
        }

        // Goatee: rounded box around mouth and chin.
        let gA = mouthHalfWidth + 0.012 + neck * 0.006
        let gTop = mc.y + 0.30 * h + cheek * 0.12 * h
        let gBottom = chin.y - 0.004
        let gCy = 0.5 * (gTop + gBottom), gB = 0.5 * (gTop - gBottom)

        let neckCentre: Float = (style == .full ? 0.038 : 0.030) + neck * 0.012

        var a0 = [SIMD4<Float>](repeating: .zero, count: all.count)
        var a1 = [SIMD4<Float>](repeating: .zero, count: all.count)
        for j in 0..<all.count {
            let p = all[j]
            let ax = abs(p.x)
            let ring = ringOf(j)
            if ring == 0 {
                let lip = (1 - smooth(mouthHalfWidth * 1.0, mouthHalfWidth * 1.12, ax))
                    * smooth(mc.y - 0.013 * lipScale, mc.y - 0.010 * lipScale, p.y)
                    * (1 - smooth(mc.y + 0.008 * lipScale, mc.y + 0.011 * lipScale, p.y))
                let growth = (1 - smooth(-0.002, 0.006, p.y - growthTop(ax))) * (1 - lip)
                let s: Float
                if style == .goatee {
                    let q = pow(pow(ax / gA, 4) + pow(abs(p.y - gCy) / gB, 4), 0.25)
                    s = (q - 1) * min(gA, gB)
                } else {
                    s = p.y - topY(ax)
                }
                a0[j] = SIMD4(s, lip, 0, growth)
                a1[j] = SIMD4(p.x, p.y, 0, 0)
            } else {
                let t = min(ax / max(maxJawX, 1e-3), 1)
                let d = Float(ring) * Self.ringStep
                let neckDist = neckCentre + (0.010 - neckCentre) * (t * t)
                let s: Float = style == .goatee ? 0.01 : d - neckDist
                let growth = 1 - smooth(Float(Self.rings - 1), Float(Self.rings), Float(ring))
                a0[j] = SIMD4(s, 0, 1, growth)
                a1[j] = SIMD4(p.x, chin.y - d, 0, 0)
            }
        }
        // Symmetry is measured on the cheek line between the moustache and the sideburn
        // (goatee: on its two side walls), away from the eyes.
        let sym: SIMD4<Float> = style == .goatee
            ? SIMD4(0.4 * gA, gA + 0.016, gCy - 0.5 * gB, gCy + 0.5 * gB)
            : SIMD4(axT + 0.004, axS - 0.010, chin.y - 0.02, ey - 0.30 * h)
        return VertexAttributes(a0: a0, a1: a1, sym: sym)
    }

    // MARK: - Brows

    struct BrowLevels { var alaY: Float; var lidTop: Float; var browTop: Float }

    /// Levels for the brow guides; uses the person's own brow height once it is learned.
    func browLevels(_ personal: PersonalLandmarks?) -> BrowLevels {
        let alaY = personal.map { 0.5 * ($0.ala[0].y + $0.ala[1].y) } ?? (eyeY - 0.55 * eyeToMouth)
        let top = personal.map { $0.browTop + 0.005 } ?? (eyeY + 0.036)
        return BrowLevels(alaY: alaY, lidTop: eyeY + 0.006, browTop: top)
    }

    /// The three brow lines start at the side of the nose (ala) and pass through the inner eye corner,
    /// the outer edge of the iris (looking straight ahead) and the outer eye corner. With `personal`
    /// set, the nose sides and pupils are the person's own (learned with Vision); otherwise estimated.
    func browAttributes(_ personal: PersonalLandmarks?) -> VertexAttributes {
        let all = positions(neutral)
        let ey = eyeY
        let lv = browLevels(personal)
        // Per side, per line: a point on the line and its normal pointing towards the nose.
        var lines: [[(SIMD2<Float>, SIMD2<Float>)]] = []
        for side in 0..<2 {
            let inner = eyeInner[side], outer = eyeOuter[side]
            let sgn: Float = side == 0 ? -1 : 1
            let ala = personal?.ala[side] ?? SIMD2(inner.x * 1.05 + sgn * 0.001, lv.alaY)
            let irisEdge = personal.map { $0.pupil[side] + SIMD2(sgn * 0.0055, 0) }
                ?? SIMD2(inner.x + (outer.x - inner.x) * 0.62, inner.y + 0.5 * (outer.y - inner.y))
            let targets = [SIMD2(inner.x, inner.y), irisEdge, SIMD2(outer.x, outer.y)]
            lines.append(targets.map { tg -> (SIMD2<Float>, SIMD2<Float>) in
                let d = simd_normalize(tg - ala)
                var n = SIMD2(-d.y, d.x)
                if n.x * (-sgn) < 0 { n = -n }
                return (ala, n)
            })
        }
        var a0 = [SIMD4<Float>](repeating: .zero, count: all.count)
        var a1 = [SIMD4<Float>](repeating: .zero, count: all.count)
        for j in 0..<faceVertexCount {
            let p = all[j]
            let side = p.x < 0 ? 0 : 1
            let q = SIMD2(p.x, p.y)
            let f = lines[side].map { simd_dot(q - $0.0, $0.1) }
            let zone = smooth(0.0, 0.0015, f[0]) * smooth(ey + 0.008, ey + 0.011, p.y)
                * (1 - smooth(ey + 0.028, ey + 0.031, p.y))
            a0[j] = SIMD4(f[0], f[1], f[2], 1)
            a1[j] = SIMD4(p.x, p.y, zone, 0)
        }
        return VertexAttributes(a0: a0, a1: a1)
    }
}
