#if os(iOS)
import ARKit
#endif
import simd

/// Where each makeup product goes on the ARKit face mesh.
///
/// Regions are found from the mesh topology instead of hard-coded vertex numbers:
/// the ARKit face mesh has four open boundaries — the outer face contour, the two
/// eye openings and the mouth opening. The mouth boundary is the exact inner lip
/// line and the eye boundaries are the eyelid margins, so lips, eyelids and the
/// lash line can be placed from them. Weights are computed once on the neutral
/// face and then follow the live mesh through every expression.
struct EyeInfo {
    /// Upper-eyelid margin, ordered from the inner corner to the outer corner.
    var upperChain: [Int]
    /// Every vertex on the eye opening (used for its centre).
    var loop: [Int]
}

struct FaceRegions {
    /// Per-vertex weights: x = lips, y = eyeshadow, z = blush, w = 1 (face coverage).
    var weights: [SIMD4<Float>]
    var leftEye: EyeInfo
    var rightEye: EyeInfo
    /// Two cheek vertices used to sample the person's own skin tone each frame.
    var skinSampleVertices: [Int]
    /// Six vertices in the middle of the lips used to sample the natural lip colour each frame.
    var lipSampleVertices: [Int]

    #if os(iOS)
    static func build(from geo: ARFaceGeometry, blush: BlushPlacement = .standard) -> FaceRegions? {
        build(vertices: geo.vertices, triangleIndices: geo.triangleIndices.map { Int(UInt16(bitPattern: $0)) }, blush: blush)
    }
    #endif

    static func build(vertices verts: [SIMD3<Float>], triangleIndices tris: [Int],
                      blush: BlushPlacement = .standard) -> FaceRegions? {
        let n = verts.count
        let triCount = tris.count / 3
        guard n > 0, triCount > 0 else { return nil }

        // --- 1. Boundary edges (edges used by exactly one triangle) ---------------
        func key(_ a: Int, _ b: Int) -> Int { a < b ? (a << 16) | b : (b << 16) | a }
        var edgeCount: [Int: Int] = [:]
        var edgeThird: [Int: Int] = [:]
        for t in 0..<triCount {
            let a = tris[3 * t], b = tris[3 * t + 1], c = tris[3 * t + 2]
            for (p, q, r) in [(a, b, c), (b, c, a), (c, a, b)] {
                let k = key(p, q)
                edgeCount[k, default: 0] += 1
                edgeThird[k] = r
            }
        }
        var adj: [Int: [Int]] = [:]
        for (k, cnt) in edgeCount where cnt == 1 {
            let a = k >> 16, b = k & 0xFFFF
            adj[a, default: []].append(b)
            adj[b, default: []].append(a)
        }

        // --- 2. Trace boundary loops ---------------------------------------------
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

        func bbox(_ loop: [Int]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in loop { lo = simd_min(lo, verts[i]); hi = simd_max(hi, verts[i]) }
            return (lo, hi)
        }
        func centroid(_ loop: [Int]) -> SIMD3<Float> {
            loop.reduce(SIMD3<Float>(repeating: 0)) { $0 + verts[$1] } / Float(loop.count)
        }

        // Outer contour = widest loop. Of the rest, keep the three widest:
        // the lowest is the mouth, the other two are the eyes.
        let byWidth = loops.sorted {
            let a = bbox($0), b = bbox($1)
            return (a.max.x - a.min.x) > (b.max.x - b.min.x)
        }
        let inner = Array(byWidth.dropFirst().prefix(3))
        guard inner.count == 3 else { return nil }
        let sortedByY = inner.sorted { centroid($0).y < centroid($1).y }
        let mouthLoop = sortedByY[0]
        let eyeLoops = sortedByY[1...].sorted { centroid($0).x < centroid($1).x }
        let eyeA = eyeLoops[0], eyeB = eyeLoops[1]

        // --- 3. Split a loop into its upper and lower chains at the corners --------
        func splitChains(_ loop: [Int]) -> (upper: [Int], lower: [Int]) {
            let iMin = loop.indices.min { verts[loop[$0]].x < verts[loop[$1]].x }!
            let iMax = loop.indices.max { verts[loop[$0]].x < verts[loop[$1]].x }!
            func walk(_ from: Int, _ to: Int) -> [Int] {
                var r: [Int] = []
                var i = from
                while true {
                    r.append(loop[i])
                    if i == to { break }
                    i = (i + 1) % loop.count
                }
                return r
            }
            let a = walk(iMin, iMax)
            let b = walk(iMax, iMin).reversed().map { $0 }
            // The chain whose neighbouring triangles sit above it is the upper one.
            func sideScore(_ chain: [Int]) -> Float {
                var s: Float = 0
                var c = 0
                for j in 0..<(chain.count - 1) {
                    if let t = edgeThird[key(chain[j], chain[j + 1])] {
                        s += verts[t].y - 0.5 * (verts[chain[j]].y + verts[chain[j + 1]].y)
                        c += 1
                    }
                }
                return c > 0 ? s / Float(c) : 0
            }
            return sideScore(a) > sideScore(b) ? (a, b) : (b, a)
        }

        /// Piecewise-linear y(x) along a chain (clamped at the ends).
        func interpolator(_ chain: [Int]) -> (Float) -> Float {
            let pts = chain.map { (verts[$0].x, verts[$0].y) }.sorted { $0.0 < $1.0 }
            return { x in
                guard let first = pts.first, let last = pts.last else { return 0 }
                if x <= first.0 { return first.1 }
                if x >= last.0 { return last.1 }
                for i in 1..<pts.count where pts[i].0 >= x {
                    let (x0, y0) = pts[i - 1], (x1, y1) = pts[i]
                    let t = (x - x0) / max(x1 - x0, 1e-6)
                    return y0 + (y1 - y0) * t
                }
                return last.1
            }
        }

        func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(max((x - e0) / (e1 - e0), 0), 1)
            return t * t * (3 - 2 * t)
        }

        var weights = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1), count: n)

        // --- 4. Lips ---------------------------------------------------------------
        let mouth = splitChains(mouthLoop)
        let upperLipY = interpolator(mouth.upper)
        let lowerLipY = interpolator(mouth.lower)
        let mb = bbox(mouthLoop)
        let mouthCX = 0.5 * (mb.min.x + mb.max.x)
        let mouthHalfW = max(0.5 * (mb.max.x - mb.min.x), 0.01)
        let mouthC = centroid(mouthLoop)
        let lipScale = mouthHalfW / 0.025
        let upperH: Float = 0.0092 * lipScale
        let lowerH: Float = 0.0115 * lipScale

        // Lip height profiles across the mouth (t = 0 centre, 1 = corner),
        // with a Cupid's bow on the upper lip.
        func upperProfile(_ t: Float) -> Float {
            let base = 0.12 + 0.88 * pow(max(0, 1 - t * t), 0.6)
            let bowDip = 1 - 0.18 * exp(-pow(t / 0.09, 2))
            let bowPeaks = 1 + 0.10 * exp(-pow((t - 0.24) / 0.1, 2))
            return base * bowDip * bowPeaks
        }
        func lowerProfile(_ t: Float) -> Float {
            0.10 + 0.90 * pow(max(0, 1 - pow(t, 2.2)), 0.55)
        }

        for i in 0..<n {
            let v = verts[i]
            let t = abs(v.x - mouthCX) / mouthHalfW
            guard t < 1.35, v.z > mouthC.z - 0.03 else { continue }
            let yu = upperLipY(v.x), yl = lowerLipY(v.x)
            var w: Float
            if v.y >= yu - 0.0003 {
                let d = max(0, v.y - yu)
                let th = upperProfile(min(t, 1)) * upperH
                w = 1 - smoothstep(0.4 * th, 1.6 * th, d)
            } else if v.y <= yl + 0.0003 {
                let d = max(0, yl - v.y)
                let th = lowerProfile(min(t, 1)) * lowerH
                w = 1 - smoothstep(0.4 * th, 1.6 * th, d)
            } else {
                w = 1
            }
            w *= 1 - smoothstep(1.0, 1.35, t)   // reach into the mouth corners, then fade
            weights[i].x = w
        }

        // Lip colour sample points: middle of the upper and lower lip at three positions across.
        var lipSamples: [Int] = []
        for (targetT, isUpper) in [(-0.45, true), (0, true), (0.45, true), (-0.45, false), (0, false), (0.45, false)] as [(Float, Bool)] {
            var best = -1
            var bestScore = Float.greatestFiniteMagnitude
            for i in 0..<n {
                let v = verts[i]
                let ts = (v.x - mouthCX) / mouthHalfW
                guard abs(ts) < 0.9 else { continue }
                let yu = upperLipY(v.x), yl = lowerLipY(v.x)
                let d: Float, th: Float
                if isUpper {
                    guard v.y >= yu else { continue }
                    d = v.y - yu
                    th = upperProfile(abs(ts)) * upperH
                } else {
                    guard v.y <= yl else { continue }
                    d = yl - v.y
                    th = lowerProfile(abs(ts)) * lowerH
                }
                let dx = (ts - targetT) * mouthHalfW
                let score = dx * dx + (d - 0.45 * th) * (d - 0.45 * th)
                if score < bestScore { bestScore = score; best = i }
            }
            if best >= 0 { lipSamples.append(best) }
        }
        while lipSamples.count < 6, let first = lipSamples.first { lipSamples.append(first) }

        // --- 5. Eyes: eyeshadow on the upper lid + liner chains ---------------------
        func eyeInfo(_ loop: [Int]) -> EyeInfo {
            let chains = splitChains(loop)
            let c = centroid(loop)
            // Outer corner is the one farther from the face midline.
            let upper = c.x >= 0 ? chains.upper : chains.upper.reversed()
            return EyeInfo(upperChain: upper, loop: loop)
        }
        let leftEye = eyeInfo(eyeA)
        let rightEye = eyeInfo(eyeB)

        for eyeLoop in [eyeA, eyeB] {
            let chains = splitChains(eyeLoop)
            let lidY = interpolator(chains.upper)
            let eb = bbox(eyeLoop)
            let ecx = 0.5 * (eb.min.x + eb.max.x)
            let ehw = max(0.5 * (eb.max.x - eb.min.x), 0.005)
            let outward: Float = ecx >= 0 ? 1 : -1
            let eyeScale = ehw / 0.0145
            for i in 0..<n {
                let v = verts[i]
                let tx = (v.x - ecx) / ehw * outward      // > 0 towards the outer corner
                guard tx > -1.3, tx < 1.6 else { continue }
                let d = v.y - lidY(v.x)
                guard d > -0.001 else { continue }
                let height = (0.009 + 0.004 * smoothstep(0, 1.2, tx)) * eyeScale
                var w = smoothstep(-0.0005, 0.0012, d) * (1 - smoothstep(0.6 * height, 1.25 * height, d))
                w *= 1 - smoothstep(0.95, 1.25, -tx)        // inner corner fade
                w *= 1 - smoothstep(1.05, 1.55, tx)         // outer corner fade
                w *= 0.7 + 0.3 * smoothstep(-0.6, 0.9, tx)  // deeper towards the outer corner
                weights[i].y = max(weights[i].y, w)
            }
        }

        // --- 6. Blush on the apples of the cheeks ----------------------------------
        let eyeCentres = [centroid(eyeA), centroid(eyeB)]
        let eyeDist = max(abs(eyeCentres[1].x - eyeCentres[0].x), 0.03)
        let faceScale = eyeDist / 0.064
        var skinSamples: [Int] = []
        for ec in eyeCentres {
            let cheek = SIMD2<Float>(ec.x * blush.out, ec.y - blush.down * (ec.y - mouthC.y))
            let rx: Float = blush.rx * faceScale, ry: Float = blush.ry * faceScale
            let tilt: Float = (ec.x >= 0 ? 1 : -1) * blush.tilt   // lift towards the temples
            let cs = cos(tilt), sn = sin(tilt)
            for i in 0..<n {
                let v = verts[i]
                let dx = v.x - cheek.x, dy = v.y - cheek.y
                let rx2 = cs * dx + sn * dy, ry2 = -sn * dx + cs * dy
                let g = exp(-1.6 * (rx2 * rx2 / (rx * rx) + ry2 * ry2 / (ry * ry)))
                let w = g * (1 - weights[i].x) * (1 - weights[i].y)
                weights[i].z = max(weights[i].z, w)
            }
            // Skin sample point: a bit inside the blush centre, on plain cheek skin.
            let target = SIMD2<Float>(ec.x * 0.95, ec.y - 0.45 * (ec.y - mouthC.y))
            var best = 0
            var bestD = Float.greatestFiniteMagnitude
            for i in 0..<n {
                let d = simd_distance_squared(SIMD2(verts[i].x, verts[i].y), target)
                if d < bestD && verts[i].z > mouthC.z - 0.03 { bestD = d; best = i }
            }
            skinSamples.append(best)
        }

        return FaceRegions(weights: weights, leftEye: leftEye, rightEye: rightEye,
                           skinSampleVertices: skinSamples, lipSampleVertices: lipSamples)
    }
}

extension FaceRegions {
    static let linerPointsPerEye = 14

    /// Lash-line polyline in screen pixels: (x, y, half-thickness, s).
    /// Sits just above the upper-lid margin, thickens towards the outer corner and ends in a wing.
    /// `pixelsPerMetre` is the true scale at the face (not foreshortened): an eye that is turning away
    /// from the camera looks narrower than that, and its wing is drawn shorter so it stays on the face.
    static func linerPolyline(eye: EyeInfo, verts: [SIMD3<Float>], thickness: Float, wing: Float, pixelsPerMetre: Float,
                              project: (SIMD3<Float>) -> SIMD2<Float>) -> [SIMD4<Float>] {
        let raw = eye.upperChain.map { project(verts[$0]) }
        let centre3 = eye.loop.reduce(SIMD3<Float>(repeating: 0)) { $0 + verts[$1] } / Float(max(eye.loop.count, 1))
        let centre = project(centre3)
        guard raw.count >= 2 else { return [] }

        // Resample evenly by arc length.
        var cum: [Float] = [0]
        for i in 1..<raw.count { cum.append(cum[i - 1] + simd_distance(raw[i], raw[i - 1])) }
        let total = max(cum.last!, 1)
        let n = linerPointsPerEye
        var pts: [SIMD2<Float>] = []
        var j = 1
        for k in 0..<n {
            let target = total * Float(k) / Float(n - 1)
            while j < raw.count - 1 && cum[j] < target { j += 1 }
            let segLen = max(cum[j] - cum[j - 1], 1e-4)
            let f = min(max((target - cum[j - 1]) / segLen, 0), 1)
            pts.append(raw[j - 1] + (raw[j] - raw[j - 1]) * f)
        }

        let eyeWidth = simd_distance(pts.first!, pts.last!)
        let thicknessScale = thickness
        var out: [SIMD4<Float>] = []
        for k in 0..<n {
            let s = Float(k) / Float(n - 1)
            let prev = pts[max(k - 1, 0)], next = pts[min(k + 1, n - 1)]
            let tangent = simd_normalize(next - prev)
            var normal = SIMD2<Float>(-tangent.y, tangent.x)
            if simd_dot(normal, pts[k] - centre) < 0 { normal = -normal }  // point away from the eye
            let th = (0.010 + 0.040 * pow(s, 1.4)) * eyeWidth * thicknessScale
            let p = pts[k] + normal * th * 0.65
            out.append(SIMD4(p.x, p.y, th, s))
        }
        // Wing: continue past the outer corner, angled up towards the temple.
        let last = pts[n - 1], before = pts[n - 2]
        let tangent = simd_normalize(last - before)
        var up = SIMD2<Float>(-tangent.y, tangent.x)
        if simd_dot(up, last - centre) < 0 { up = -up }
        let wingDir = simd_normalize(tangent * 0.85 + up * 0.55)
        let lastPt = out[n - 1]
        let width3D = eye.upperChain.count >= 2
            ? simd_distance(verts[eye.upperChain.first!], verts[eye.upperChain.last!]) * pixelsPerMetre : eyeWidth
        let facing = min(max((eyeWidth / max(width3D, 1) - 0.70) / 0.22, 0), 1)
        let tip = SIMD2(lastPt.x, lastPt.y) + wingDir * 0.26 * eyeWidth * wing * facing * facing * (3 - 2 * facing)
        out.append(SIMD4(tip.x, tip.y, 0.6, 1.2))
        return out
    }
}
