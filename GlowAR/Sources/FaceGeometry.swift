#if os(iOS)
import ARKit
#endif
import simd

/// The person's own landmarks, in neutral face coordinates (x, y in metres).
struct PersonalLandmarks {
    var ala: [SIMD2<Float>]     // side of the nose, [-x side, +x side]
    var pupil: [SIMD2<Float>]
    var browTop: Float          // highest point of the brows
    var samples: Int
}

/// Face landmarks found from the ARKit mesh topology (its open boundaries are the face outline,
/// the eye openings and the mouth opening). Used by the skin care, the glow and contour areas,
/// the brow guide and the face measurements.
/// Coordinates are those of ARKit's neutral face, in metres; +x is the person's own left.
final class FaceGeometry {
    let neutral: [SIMD3<Float>]
    let tris: [Int]
    let triCount: Int
    let eyeInnerIdx: [Int]         // vertex indices of the eye corners, index 0 = -x side, 1 = +x side
    let eyeOuterIdx: [Int]
    let eyeInner: [SIMD3<Float>]
    let eyeOuter: [SIMD3<Float>]
    let eyeCenter: [SIMD3<Float>]
    let mouthCenter: SIMD3<Float>
    let mouthHalfWidth: Float
    let noseTip: SIMD3<Float>
    let chin: SIMD3<Float>
    private let outerLoop: [Int]
    private let eyeLoops: [[Int]]
    private let mouthLoop: [Int]
    private let cheekIdx: [[Int]]  // outline vertices at cheekbone height, per side
    private let jawIdx: [[Int]]    // outline vertices at the jaw corners, per side
    private let chinIdx: Int

    var eyeY: Float { 0.5 * (eyeCenter[0].y + eyeCenter[1].y) }
    var eyeX: Float { 0.5 * (abs(eyeCenter[0].x) + abs(eyeCenter[1].x)) }
    var eyeToMouth: Float { eyeY - mouthCenter.y }

    #if os(iOS)
    convenience init?(_ geo: ARFaceGeometry) {
        self.init(vertices: geo.vertices, triangleIndices: geo.triangleIndices.map { Int(UInt16(bitPattern: $0)) })
    }
    #endif

    init?(vertices v: [SIMD3<Float>], triangleIndices: [Int]) {
        neutral = v
        tris = triangleIndices
        triCount = triangleIndices.count / 3
        guard !v.isEmpty, triCount > 0 else { return nil }

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
        let eyes = inner[1...].sorted { centroid($0).x < centroid($1).x }
        outerLoop = outer
        mouthLoop = inner[0]
        eyeLoops = eyes

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
        let mc = centroid(inner[0])
        mouthCenter = mc
        mouthHalfWidth = max(0.5 * width(inner[0]), 0.01)
        noseTip = v.max { $0.z < $1.z }!

        // Outline points used to measure the face shape (same vertices on the live mesh).
        let eyY = 0.5 * (ec[0].y + ec[1].y)
        let e2m = eyY - mc.y
        func outline(_ y: Float, _ side: Float) -> [Int] {
            Array(outer.filter { v[$0].x * side > 0.02 }.sorted { abs(v[$0].y - y) < abs(v[$1].y - y) }.prefix(2))
        }
        cheekIdx = [outline(eyY - 0.15 * e2m, -1), outline(eyY - 0.15 * e2m, 1)]
        jawIdx = [outline(mc.y - 0.05 * e2m, -1), outline(mc.y - 0.05 * e2m, 1)]
        chinIdx = outer.filter { abs(v[$0].x) < 0.02 }.min { v[$0].y < v[$1].y } ?? outer.min { v[$0].y < v[$1].y }!
        chin = v[chinIdx]
        guard cheekIdx.allSatisfy({ !$0.isEmpty }), jawIdx.allSatisfy({ !$0.isEmpty }) else { return nil }
    }

    /// Clean-skin patch on the upper cheeks: |x| min, |x| max, y min, y max.
    /// The hair detector learns the person's skin texture and the camera noise there,
    /// and the skin colour (undertone) is read from it.
    var refRegion: SIMD4<Float> {
        SIMD4(0.024, 0.048, eyeY - 0.36 * eyeToMouth, eyeY - 0.17 * eyeToMouth)
    }

    /// Area that holds the brows, used to measure how dark they are against the skin.
    /// With the person's own brow height once it is known.
    func browBox(_ personal: PersonalLandmarks?) -> SIMD4<Float> {
        if let p = personal { return SIMD4(0.012, 0.046, p.browTop - 0.014, p.browTop + 0.001) }
        return SIMD4(0.012, 0.046, eyeY + 0.014, eyeY + 0.034)
    }

    // MARK: - Skin

    /// Vertices in the middle of the forehead and on the chin. Together with the cheeks they give
    /// the person's average skin colour, which "even tone" pulls the skin towards.
    var toneVertices: [Int] {
        [SIMD2<Float>(0, eyeY + 0.55 * eyeToMouth), SIMD2<Float>(0, mouthCenter.y - 0.42 * eyeToMouth)].map { target in
            neutral.indices.filter { neutral[$0].z > mouthCenter.z - 0.04 }.min {
                simd_distance_squared(SIMD2(neutral[$0].x, neutral[$0].y), target)
                    < simd_distance_squared(SIMD2(neutral[$1].x, neutral[$1].y), target)
            } ?? 0
        }
    }

    /// Where skin care (smoothing, even tone) applies, per vertex: 1 on open skin, fading to 0 towards
    /// the edge of the mesh, the eyelid margins and the mouth opening, and off on the lips.
    func skinWeights(lips: [Float]) -> [Float] {
        func dist(_ p: SIMD3<Float>, _ loop: [Int]) -> Float {
            var best = Float.greatestFiniteMagnitude
            for i in loop.indices {
                let a = neutral[loop[i]], b = neutral[loop[(i + 1) % loop.count]]
                let e = b - a
                let h = min(max(simd_dot(p - a, e) / max(simd_length_squared(e), 1e-12), 0), 1)
                best = min(best, simd_distance(p, a + e * h))
            }
            return best
        }
        func ramp(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(max((x - e0) / (e1 - e0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        return neutral.indices.map { i in
            let p = neutral[i]
            var w = ramp(0.002, 0.014, dist(p, outerLoop))
            for eye in eyeLoops { w *= ramp(0.001, 0.005, dist(p, eye)) }
            w *= ramp(0.0005, 0.004, dist(p, mouthLoop))
            return w * (1 - (i < lips.count ? lips[i] : 0))
        }
    }

    // MARK: - Measurements

    /// Face proportions on any set of face vertices (neutral or live):
    /// x = length (between the eyes to the chin) / cheekbone width, y = jaw width / cheekbone width.
    func shapeRatios(_ v: [SIMD3<Float>]) -> SIMD2<Float> {
        func mid(_ idx: [Int]) -> SIMD3<Float> { idx.reduce(.zero) { $0 + v[$1] } / Float(idx.count) }
        let wCheek = max(simd_distance(mid(cheekIdx[0]), mid(cheekIdx[1])), 1e-4)
        let wJaw = simd_distance(mid(jawIdx[0]), mid(jawIdx[1]))
        let top = 0.5 * (v[eyeInnerIdx[0]] + v[eyeInnerIdx[1]])
        return SIMD2(simd_distance(top, v[chinIdx]) / wCheek, wJaw / wCheek)
    }

    /// Eye proportions on any set of face vertices (neutral or live):
    /// x = gap between the inner corners / eye width, y = tilt in radians (+ = outer corner higher).
    func eyeRatios(_ v: [SIMD3<Float>]) -> SIMD2<Float> {
        var width: Float = 0, tilt: Float = 0
        for s in 0..<2 {
            let i = v[eyeInnerIdx[s]], o = v[eyeOuterIdx[s]]
            width += 0.5 * simd_distance(i, o)
            tilt += 0.5 * atan2(o.y - i.y, max(abs(o.x - i.x), 1e-5))
        }
        let gap = simd_distance(v[eyeInnerIdx[0]], v[eyeInnerIdx[1]])
        return SIMD2(gap / max(width, 1e-4), tilt)
    }

    // MARK: - Brows

    struct BrowLevels { var alaY: Float; var lidTop: Float; var browTop: Float }

    /// Levels for the brow guide; uses the person's own brow height once it is learned.
    func browLevels(_ personal: PersonalLandmarks?) -> BrowLevels {
        let alaY = personal.map { 0.5 * ($0.ala[0].y + $0.ala[1].y) } ?? (eyeY - 0.55 * eyeToMouth)
        let top = personal.map { $0.browTop + 0.005 } ?? (eyeY + 0.036)
        return BrowLevels(alaY: alaY, lidTop: eyeY + 0.006, browTop: top)
    }

    /// Zone around the brow where single stray hairs are marked: y min, y max, reach past the end line,
    /// and the eye line y. From under the brow (above the eyelid) to just over it, 6 mm past its end.
    func aroundBrowZone(_ personal: PersonalLandmarks?) -> SIMD4<Float> {
        let lv = browLevels(personal)
        return SIMD4(max(eyeY + 0.012, lv.browTop - 0.021), lv.browTop - 0.001, 0.006, eyeY)
    }

    /// The three brow lines as shader data. Each line starts at the side of the nose (ala) and passes
    /// through the inner eye corner (start), the outer edge of the iris looking straight ahead (arch)
    /// and the outer eye corner (end). With `personal` set, the nose sides and pupils are the person's
    /// own (learned with Vision); otherwise estimated.
    ///  ala: -x side (xy), +x side (zw);  normals[k]: line k, -x side (xy), +x side (zw), pointing to the nose.
    func browLines(_ personal: PersonalLandmarks?) -> (ala: SIMD4<Float>, normals: [SIMD4<Float>]) {
        let lv = browLevels(personal)
        var alas: [SIMD2<Float>] = []
        var normals: [[SIMD2<Float>]] = []
        for side in 0..<2 {
            let inner = eyeInner[side], outer = eyeOuter[side]
            let sgn: Float = side == 0 ? -1 : 1
            let ala = personal?.ala[side] ?? SIMD2(inner.x * 1.05 + sgn * 0.001, lv.alaY)
            let irisEdge = personal.map { $0.pupil[side] + SIMD2(sgn * 0.0055, 0) }
                ?? SIMD2(inner.x + (outer.x - inner.x) * 0.62, inner.y + 0.5 * (outer.y - inner.y))
            alas.append(ala)
            normals.append([SIMD2(inner.x, inner.y), irisEdge, SIMD2(outer.x, outer.y)].map { target in
                let d = simd_normalize(target - ala)
                var n = SIMD2(-d.y, d.x)
                if n.x * (-sgn) < 0 { n = -n }
                return n
            })
        }
        return (SIMD4(alas[0].x, alas[0].y, alas[1].x, alas[1].y),
                (0..<3).map { k in SIMD4(normals[0][k].x, normals[0][k].y, normals[1][k].x, normals[1][k].y) })
    }
}
