import CoreVideo
import Metal
import Vision
import simd

/// Layout must match `PaintUniforms` in Shaders.metal.
struct PaintUniforms {
    var mvp: simd_float4x4
    var viewSize: SIMD4<Float>
    var params: SIMD4<Float>
}

/// Learns the person's real lip outline.
///
/// Vision finds the outer lip contour on an upright copy of the camera frame. That contour is
/// painted into a texture in the face mesh's UV space and averaged over many frames, so the
/// result matches this person's lips and moves with the ARKit mesh with no lag.
final class LipCalibrator {
    struct Snapshot {
        var positions: [SIMD3<Float>]
        var mvp: simd_float4x4
        var size: CGSize
        var mouthCenter: SIMD2<Float>   // drawable pixels
    }

    private struct Job {
        var polygon: [SIMD2<Float>]
        var snap: Snapshot
    }

    let lipUVTex: MTLTexture
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var needsClear = true
    private(set) var paintsDone = 0

    private var cache: CVMetalTextureCache?
    private var pixelBuffer: CVPixelBuffer?
    private var cvTexture: CVMetalTexture?
    private var visionTexture: MTLTexture?
    private var visionSize = CGSize.zero

    private let queue = DispatchQueue(label: "glowar.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var pending: Job?
    private var lastStart: CFTimeInterval = 0

    /// 0 = nothing learned yet, 1 = fully trust the learned outline.
    var calibration: Float { min(1, Float(paintsDone) / 6) }

    init?(device: MTLDevice, library: MTLLibrary) {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "lipPaintVertex")
        d.fragmentFunction = library.makeFunction(name: "lipPaintFragment")
        guard let ca = d.colorAttachments[0] else { return nil }
        ca.pixelFormat = .r16Float
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.alphaBlendOperation = .add
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .zero
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 2048, height: 2048,
                                                          mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        guard let t = device.makeTexture(descriptor: td) else { return nil }

        self.device = device
        self.pipeline = p
        self.lipUVTex = t
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// A texture to render the upright camera frame into, or nil when Vision is still busy.
    func beginCapture(drawableSize: CGSize, now: CFTimeInterval) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        guard !busy, now - lastStart > 0.08 else { return nil }
        ensureBuffer(drawableSize)
        guard let tex = visionTexture else { return nil }
        busy = true
        lastStart = now
        return tex
    }

    /// Call once the GPU has finished writing the upright frame.
    func runVision(_ snap: Snapshot) {
        queue.async { [weak self] in self?.detect(snap) }
    }

    private func ensureBuffer(_ size: CGSize) {
        let w = 720
        let h = Int((CGFloat(w) * size.height / max(size.width, 1)).rounded())
        if pixelBuffer != nil, Int(visionSize.width) == w, Int(visionSize.height) == h { return }
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb, let cache else { return }
        let texAttrs = [kCVMetalTextureUsage as String: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue] as CFDictionary
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, texAttrs, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        pixelBuffer = pb
        cvTexture = cvTex
        visionTexture = tex
        visionSize = CGSize(width: w, height: h)
    }

    private func detect(_ snap: Snapshot) {
        var job: Job?
        defer {
            lock.lock()
            if let job { pending = job }
            busy = false
            lock.unlock()
        }
        guard let pb = pixelBuffer else { return }
        let req = VNDetectFaceLandmarksRequest()
        req.constellation = .constellation76Points
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        guard (try? handler.perform([req])) != nil,
              let obs = req.results?.first, obs.confidence > 0.5,
              let outer = obs.landmarks?.outerLips, outer.pointCount >= 6 else { return }

        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        let pts = outer.pointsInImage(imageSize: CGSize(width: w, height: h))
        let sx = Float(snap.size.width / w), sy = Float(snap.size.height / h)
        // Vision uses a bottom-left origin; pick whichever orientation lands on the tracked mouth.
        let flipped = pts.map { SIMD2<Float>(Float($0.x) * sx, Float(h - $0.y) * sy) }
        let straight = pts.map { SIMD2<Float>(Float($0.x) * sx, Float($0.y) * sy) }
        func centroid(_ p: [SIMD2<Float>]) -> SIMD2<Float> { p.reduce(.zero, +) / Float(p.count) }
        let dF = simd_distance(centroid(flipped), snap.mouthCenter)
        let dS = simd_distance(centroid(straight), snap.mouthCenter)
        let poly = dF <= dS ? flipped : straight
        guard min(dF, dS) < 0.08 * Float(snap.size.width) else { return }
        job = Job(polygon: Self.catmullRom(poly, samples: 4), snap: snap)
    }

    /// Encodes the paint pass for the latest Vision result (or the initial clear).
    func encodePaint(_ cb: MTLCommandBuffer, weights: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, indexCount: Int) {
        lock.lock()
        let job = pending
        pending = nil
        lock.unlock()

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = lipUVTex
        rp.colorAttachments[0].loadAction = needsClear ? .clear : .load
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store

        guard let job, job.polygon.count >= 3, job.polygon.count <= 128 else {
            if needsClear, let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                enc.endEncoding()
                needsClear = false
            }
            return
        }
        guard let pos = job.snap.positions.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        var u = PaintUniforms(mvp: job.snap.mvp,
                              viewSize: SIMD4(Float(job.snap.size.width), Float(job.snap.size.height),
                                              Float(job.polygon.count), 0),
                              params: SIMD4(paintsDone == 0 ? 1 : 0.25, 0, 0, 0))
        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        enc.setVertexBuffer(pos, offset: 0, index: 0)
        enc.setVertexBuffer(weights, offset: 0, index: 1)
        enc.setVertexBuffer(uvs, offset: 0, index: 2)
        enc.setVertexBytes(&u, length: MemoryLayout<PaintUniforms>.stride, index: 3)
        enc.setFragmentBytes(&u, length: MemoryLayout<PaintUniforms>.stride, index: 0)
        job.polygon.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                  indexBuffer: indices, indexBufferOffset: 0)
        enc.endEncoding()
        needsClear = false
        paintsDone += 1
    }

    /// Smooth closed curve through the Vision points.
    static func catmullRom(_ p: [SIMD2<Float>], samples: Int) -> [SIMD2<Float>] {
        let n = p.count
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(n * samples)
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            for k in 0..<samples {
                let t = Float(k) / Float(samples), t2 = t * t, t3 = t2 * t
                let a = 2 * p1
                let b = p2 - p0
                let c = 2 * p0 - 5 * p1 + 4 * p2 - p3
                let d = -p0 + 3 * p1 - 3 * p2 + p3
                out.append(0.5 * (a + b * t + c * t2 + d * t3))
            }
        }
        return out
    }
}
