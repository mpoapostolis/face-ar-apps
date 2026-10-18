import CoreVideo
import Metal
import Vision
import simd

/// Learns where this person's nose wings, pupils and brows are.
///
/// Vision reads the landmarks on an upright copy of the camera frame; each point is then mapped
/// onto the ARKit face mesh of that same frame and stored in neutral face coordinates, averaged
/// over ~20 frontal frames. The guides built from it follow the mesh, so they never lag.
final class LandmarkCalibrator {
    struct Snapshot {
        var face: [SIMD3<Float>]     // live face vertices of that frame
        var mvp: simd_float4x4
        var size: CGSize
    }

    static let target = 20
    private(set) var result: PersonalLandmarks?
    private(set) var version = 0
    var progress: Float { min(1, Float(result?.samples ?? 0) / Float(Self.target)) }
    var done: Bool { (result?.samples ?? 0) >= Self.target }

    private let geometry: FaceGeometry
    private var cache: CVMetalTextureCache?
    private var pixelBuffer: CVPixelBuffer?
    private var cvTexture: CVMetalTexture?
    private var texture: MTLTexture?
    private var bufferSize = CGSize.zero
    private let queue = DispatchQueue(label: "glowar.landmarks", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var pending: PersonalLandmarks?
    private var lastStart: CFTimeInterval = 0

    init(device: MTLDevice, geometry: FaceGeometry) {
        self.geometry = geometry
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// Texture to render the clean, unmirrored camera frame into — or nil if Vision is busy or done.
    func beginCapture(size: CGSize, now: CFTimeInterval) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        guard !busy, !done, now - lastStart > 0.12 else { return nil }
        let w = 720, h = Int((CGFloat(w) * size.height / max(size.width, 1)).rounded())
        if pixelBuffer == nil || Int(bufferSize.width) != w || Int(bufferSize.height) != h {
            let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
            guard let pb, let cache else { return nil }
            let texAttrs = [kCVMetalTextureUsage as String: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue] as CFDictionary
            var cvTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, texAttrs, .bgra8Unorm, w, h, 0, &cvTex)
            guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
            pixelBuffer = pb
            cvTexture = cvTex
            texture = tex
            bufferSize = CGSize(width: w, height: h)
        }
        busy = true
        lastStart = now
        return texture
    }

    func run(_ snap: Snapshot) {
        queue.async { [weak self] in self?.detect(snap) }
    }

    /// Picks up a finished result on the render thread. Returns true when the landmarks changed.
    func collect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pending else { return false }
        pending = nil
        result = p
        version += 1
        return true
    }

    // MARK: - Vision

    private func detect(_ snap: Snapshot) {
        var updated: PersonalLandmarks?
        defer {
            lock.lock()
            if let updated { pending = updated }
            busy = false
            lock.unlock()
        }
        guard let pb = pixelBuffer else { return }
        let req = VNDetectFaceLandmarksRequest()
        req.constellation = .constellation76Points
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first, obs.confidence > 0.6,
              let lm = obs.landmarks, let nose = lm.nose, let lp = lm.leftPupil, let rp = lm.rightPupil,
              let lb = lm.leftEyebrow, let rb = lm.rightEyebrow else { return }

        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        let sx = Float(snap.size.width / w), sy = Float(snap.size.height / h)
        let proj = projectAll(snap)

        // Vision's origin is bottom-left; check which orientation puts the nose on the mesh's nose tip.
        func pts(_ r: VNFaceLandmarkRegion2D, flip: Bool) -> [SIMD2<Float>] {
            r.pointsInImage(imageSize: CGSize(width: w, height: h)).map {
                SIMD2(Float($0.x) * sx, Float(flip ? h - $0.y : $0.y) * sy)
            }
        }
        let tipIdx = geometry.neutral.indices.max { geometry.neutral[$0].z < geometry.neutral[$1].z }!
        let tip = proj[tipIdx].xy
        func centroid(_ p: [SIMD2<Float>]) -> SIMD2<Float> { p.reduce(.zero, +) / Float(max(p.count, 1)) }
        let flip = simd_distance(centroid(pts(nose, flip: true)), tip) <= simd_distance(centroid(pts(nose, flip: false)), tip)
        guard simd_distance(centroid(pts(nose, flip: flip)), tip) < 0.08 * Float(snap.size.width) else { return }

        // Nose wings: the widest nose points, mapped onto the mesh.
        let np = pts(nose, flip: flip)
        guard let nl = np.min(by: { $0.x < $1.x }), let nr = np.max(by: { $0.x < $1.x }),
              let a0 = pick(nl, proj), let a1 = pick(nr, proj) else { return }
        let alas = [a0, a1].sorted { $0.x < $1.x }

        // Pupils sit in the eye opening (no mesh there): place them relative to the eye corners.
        // Handedness between screen (y down) and face space (y up), so "across" maps the right way.
        func cross2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        let ciL = proj[geometry.eyeInnerIdx[0]].xy, ciR = proj[geometry.eyeInnerIdx[1]].xy
        let niL = SIMD2(geometry.eyeInner[0].x, -geometry.eyeInner[0].y)
        let niR = SIMD2(geometry.eyeInner[1].x, -geometry.eyeInner[1].y)
        let nTip = SIMD2(geometry.neutral[tipIdx].x, -geometry.neutral[tipIdx].y)
        let handed: Float = cross2(ciR - ciL, tip - ciL) * cross2(niR - niL, nTip - niL) >= 0 ? 1 : -1
        var pupils: [SIMD2<Float>] = []
        for p in [pts(lp, flip: flip), pts(rp, flip: flip)].compactMap(\.first) {
            var best: (Float, SIMD2<Float>)?
            for side in 0..<2 {
                let ci = proj[geometry.eyeInnerIdx[side]].xy, co = proj[geometry.eyeOuterIdx[side]].xy
                let axis = co - ci
                let len2 = max(simd_length_squared(axis), 1e-6)
                let t = simd_dot(p - ci, axis) / len2
                let perp = (axis.x * (p.y - ci.y) - axis.y * (p.x - ci.x)) / len2   // across, in eye widths
                let dist = abs(t - 0.5) + abs(perp)
                let ni = geometry.eyeInner[side], no = geometry.eyeOuter[side]
                let nAxis = SIMD2(no.x - ni.x, no.y - ni.y)
                // Screen y grows downwards, face y upwards: flip the across term.
                let neutralPoint = SIMD2(ni.x, ni.y) + nAxis * t + SIMD2(nAxis.y, -nAxis.x) * (perp * handed)
                if best == nil || dist < best!.0 { best = (dist, neutralPoint) }
            }
            if let best { pupils.append(best.1) }
        }
        guard pupils.count == 2 else { return }
        pupils.sort { $0.x < $1.x }

        // Brow top: highest brow point on each side.
        let browYs = [pts(lb, flip: flip), pts(rb, flip: flip)].compactMap { side -> Float? in
            side.compactMap { pick($0, proj)?.y }.max()
        }
        guard browYs.count == 2 else { return }
        let browTop = 0.5 * (browYs[0] + browYs[1])

        // Running average.
        lock.lock()
        let prev = pending ?? result
        lock.unlock()
        if let prev, prev.samples > 0 {
            let n = Float(prev.samples), k = 1 / (n + 1)
            updated = PersonalLandmarks(ala: zip(prev.ala, alas).map { $0 + ($1 - $0) * k },
                                        pupil: zip(prev.pupil, pupils).map { $0 + ($1 - $0) * k },
                                        browTop: prev.browTop + (browTop - prev.browTop) * k,
                                        samples: prev.samples + 1)
        } else {
            updated = PersonalLandmarks(ala: alas, pupil: pupils, browTop: browTop, samples: 1)
        }
    }

    /// Screen pixel (xy) and clip w (z) for every face vertex of the snapshot.
    private func projectAll(_ snap: Snapshot) -> [SIMD3<Float>] {
        let W = Float(snap.size.width), H = Float(snap.size.height)
        return snap.face.map { v in
            let c = snap.mvp * SIMD4(v, 1)
            let ndc = SIMD2(c.x, c.y) / max(c.w, 1e-5)
            return SIMD3((ndc.x * 0.5 + 0.5) * W, (0.5 - ndc.y * 0.5) * H, c.w)
        }
    }

    /// Screen point -> neutral face (x, y), via the front-most mesh triangle under it.
    private func pick(_ p: SIMD2<Float>, _ proj: [SIMD3<Float>]) -> SIMD2<Float>? {
        var best: (Float, SIMD2<Float>)?
        let tris = geometry.tris
        for t in 0..<geometry.triCount {
            let ia = tris[3 * t], ib = tris[3 * t + 1], ic = tris[3 * t + 2]
            let a = proj[ia], b = proj[ib], c = proj[ic]
            let v0 = SIMD2(b.x - a.x, b.y - a.y), v1 = SIMD2(c.x - a.x, c.y - a.y), v2 = SIMD2(p.x - a.x, p.y - a.y)
            let den = v0.x * v1.y - v1.x * v0.y
            guard abs(den) > 1e-6 else { continue }
            let w1 = (v2.x * v1.y - v1.x * v2.y) / den
            let w2 = (v0.x * v2.y - v2.x * v0.y) / den
            let w0 = 1 - w1 - w2
            guard w0 >= -1e-3, w1 >= -1e-3, w2 >= -1e-3 else { continue }
            let depth = a.z * w0 + b.z * w1 + c.z * w2
            if best == nil || depth < best!.0 {
                let n = geometry.neutral
                let q = n[ia] * w0 + n[ib] * w1 + n[ic] * w2
                best = (depth, SIMD2(q.x, q.y))
            }
        }
        return best?.1
    }
}

private extension SIMD3 where Scalar == Float {
    var xy: SIMD2<Float> { SIMD2(x, y) }
}
