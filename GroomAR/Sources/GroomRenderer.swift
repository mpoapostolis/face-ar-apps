import ARKit
import CoreImage
import MetalKit
import UIKit

/// Layout must match `CompUniforms` in Shaders.metal.
private struct CompUniforms {
    var dt0 = SIMD4<Float>(repeating: 0)
    var dt1 = SIMD4<Float>(repeating: 0)
    var mode = SIMD4<Float>(repeating: 0)
    var hair = SIMD4<Float>(repeating: 0)
    var samples0 = SIMD4<Float>(repeating: 0)
    var samples1 = SIMD4<Float>(repeating: 0)
    var brow = SIMD4<Float>(repeating: 0)
    var det = SIMD4<Float>(repeating: 0)
    var skin = SIMD4<Float>(repeating: 0)
    var ref = SIMD4<Float>(repeating: 0)
    var sym = SIMD4<Float>(repeating: 0)
    var browZone = SIMD4<Float>(repeating: 0)
}

final class GroomRenderer: NSObject, MTKViewDelegate {
    let session = ARSession()
    private let settings: GroomSettings
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let maskPipeline: MTLRenderPipelineState
    private let hairPipeline: MTLRenderPipelineState
    private let compPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var textureCache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 3)

    private var geometry: FaceGeometry?
    private var landmarks: LandmarkCalibrator?
    private var shape: FaceShapeEstimator?
    private let analysis = HairAnalysis()
    private var indexBuffer: MTLBuffer?
    private var a0Buffer: MTLBuffer?
    private var a1Buffer: MTLBuffer?
    private var symRegion = SIMD4<Float>(repeating: 0)
    private var attributesKey = ""
    private var t0: MTLTexture?
    private var t1: MTLTexture?
    private var depth: MTLTexture?
    private var hairMap: MTLTexture?
    private var running = false

    // Counters written by the GPU every frame (see `Counters`), ring of 3 buffers.
    private var countBuffers: [MTLBuffer] = []
    private var countIndex = 0
    private var lastPublish: CFTimeInterval = 0
    private var dummyCounts: MTLBuffer?
    private var trackedSince: CFTimeInterval?
    private var frameIndex = 0

    private var captureCompletion: ((UIImage?) -> Void)?

    init?(view: MTKView, settings: GroomSettings) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.settings = settings

        let md = MTLRenderPipelineDescriptor()
        md.vertexFunction = lib.makeFunction(name: "maskVertex")
        md.fragmentFunction = lib.makeFunction(name: "maskFragment")
        md.colorAttachments[0].pixelFormat = .rgba16Float
        md.colorAttachments[1].pixelFormat = .rgba16Float
        md.depthAttachmentPixelFormat = .depth32Float
        let hd = MTLRenderPipelineDescriptor()
        hd.vertexFunction = lib.makeFunction(name: "compositeVertex")
        hd.fragmentFunction = lib.makeFunction(name: "hairMapFragment")
        hd.colorAttachments[0].pixelFormat = .r16Float
        let cd = MTLRenderPipelineDescriptor()
        cd.vertexFunction = lib.makeFunction(name: "compositeVertex")
        cd.fragmentFunction = lib.makeFunction(name: "compositeFragment")
        cd.colorAttachments[0].pixelFormat = .bgra8Unorm
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let mp = try? device.makeRenderPipelineState(descriptor: md),
              let hp = try? device.makeRenderPipelineState(descriptor: hd),
              let cp = try? device.makeRenderPipelineState(descriptor: cd),
              let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        maskPipeline = mp
        hairPipeline = hp
        compPipeline = cp
        depthState = ds
        super.init()

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.delegate = self

        let bytes = Counters.count * MemoryLayout<UInt32>.stride
        countBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: bytes, options: .storageModeShared) }
        dummyCounts = device.makeBuffer(length: bytes, options: .storageModeShared)

        if ARFaceTrackingConfiguration.isSupported, let neutral = ARFaceGeometry(blendShapes: [:]) {
            geometry = FaceGeometry(neutral)
            if let g = geometry {
                indexBuffer = g.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
                landmarks = LandmarkCalibrator(device: device, geometry: g)
                shape = FaceShapeEstimator(geometry: g)
            } else {
                settings.geometryFailed = true
            }
        }
    }

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            settings.unsupported = true
            return
        }
        guard !running else { return }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        running = true
    }

    func pause() {
        session.pause()
        running = false
    }

    /// Saves the next frame (camera + guides) as an image.
    func requestCapture(_ completion: @escaping (UIImage?) -> Void) {
        captureCompletion = completion
    }

    /// Cheek slider position that puts the guide on the real edge of the beard (average of both sides).
    func cheekOffsetOnBeard() -> Double? {
        guard let s = settings.symmetry, let g = geometry, settings.beardStyle != .goatee else { return nil }
        let metres = 0.5 * (s.left + s.right) / 1000
        // One slider unit moves the line by ~0.2 x the eye-to-mouth distance on average along the cheek.
        return min(max(settings.cheekOffset + metres / (0.20 * Double(g.eyeToMouth)), -1), 1)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func makeTargets(_ size: CGSize) {
        let w = max(Int(size.width), 1), h = max(Int(size.height), 1)
        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, mips: Bool = false) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: mips)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        t0 = tex(.rgba16Float, w, h)
        t1 = tex(.rgba16Float, w, h)
        depth = tex(.depth32Float, w, h)
        hairMap = tex(.r16Float, max(w / 2, 1), max(h / 2, 1), mips: true)   // about one pixel per camera pixel
    }

    private func cameraTexture(_ pb: CVPixelBuffer, _ fmt: MTLPixelFormat, _ plane: Int) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var tex: CVMetalTexture?
        return CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, plane, &tex) == kCVReturnSuccess ? tex : nil
    }

    private func updateAttributesIfNeeded() {
        guard let g = geometry else { return }
        let key: String
        switch settings.tab {
        case .beard:
            key = "beard-\(settings.beardStyle.rawValue)-\(Int(settings.cheekOffset * 50))-\(Int(settings.neckOffset * 50))"
        default:
            key = "brows-\(landmarks?.version ?? 0)"
        }
        guard key != attributesKey else { return }
        attributesKey = key
        let attrs = settings.tab == .beard
            ? g.beardAttributes(style: settings.beardStyle, cheek: Float(settings.cheekOffset), neck: Float(settings.neckOffset))
            : g.browAttributes(landmarks?.result)
        a0Buffer = attrs.a0.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        a1Buffer = attrs.a1.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        symRegion = attrs.sym
    }

    private var hairParams: SIMD4<Float> {
        switch settings.beardStyle {
        case .stubble: return SIMD4(0.00035, 0.55, 0.40, 0)
        case .short: return SIMD4(0.0016, 0.75, 0.50, 0)
        case .full: return SIMD4(0.0040, 0.90, 0.60, 0)
        case .goatee: return SIMD4(0.0018, 0.80, 0.50, 0)
        }
    }

    func draw(in view: MTKView) {
        guard running, let frame = session.currentFrame,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }
        let size = view.drawableSize
        if t0 == nil || t0!.width != Int(size.width) || t0!.height != Int(size.height) { makeTargets(size) }
        guard let t0, let t1, let depth, let hairMap else { return }
        let pb = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let yRef = cameraTexture(pb, .r8Unorm, 0), let cRef = cameraTexture(pb, .rg8Unorm, 1),
              let yTex = CVMetalTextureGetTexture(yRef), let cTex = CVMetalTextureGetTexture(cRef) else { return }

        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        cb.addCompletedHandler { [weak self] _ in
            _ = yRef; _ = cRef
            self?.inFlight.signal()
        }

        let now = CACurrentMediaTime()
        frameIndex += 1
        if landmarks?.collect() == true {
            let p = Double(landmarks?.progress ?? 0)
            if p != settings.browCalibration { settings.browCalibration = p }
        }
        updateAttributesIfNeeded()
        let face = frame.anchors.lazy.compactMap { $0 as? ARFaceAnchor }.first
        let faceOK = (face?.isTracked ?? false) && geometry != nil && a0Buffer != nil
        if faceOK != settings.faceVisible { settings.faceVisible = faceOK }
        if !faceOK { trackedSince = nil } else if trackedSince == nil { trackedSince = now }

        var u = CompUniforms()
        let t = frame.displayTransform(for: .portrait, viewportSize: size).inverted()
        u.dt0 = SIMD4(Float(t.a), Float(t.b), Float(t.c), Float(t.d))
        u.dt1 = SIMD4(Float(t.tx), Float(t.ty), Float(size.width), Float(size.height))
        u.mode = SIMD4(settings.tab == .beard ? 0 : 1, settings.mirror ? 1 : 0, settings.preview ? 1 : 0,
                       Float(view.contentScaleFactor))
        u.hair = hairParams
        u.det = analysis.det
        u.skin = analysis.skin

        var landmarkSnap: LandmarkCalibrator.Snapshot?
        var frontal = false

        // ---- Pass 1: mesh data ------------------------------------------------
        let mp = MTLRenderPassDescriptor()
        for (i, tex) in [t0, t1].enumerated() {
            mp.colorAttachments[i].texture = tex
            mp.colorAttachments[i].loadAction = .clear
            mp.colorAttachments[i].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            mp.colorAttachments[i].storeAction = .store
        }
        mp.depthAttachment.texture = depth
        mp.depthAttachment.loadAction = .clear
        mp.depthAttachment.clearDepth = 1
        mp.depthAttachment.storeAction = .dontCare
        if let enc = cb.makeRenderCommandEncoder(descriptor: mp) {
            if faceOK, let face, let g = geometry, let a0Buffer, let a1Buffer, let indexBuffer {
                let faceVerts = face.geometry.vertices
                let pos = g.positions(faceVerts)
                let proj = frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.001, zFar: 10)
                let viewM = frame.camera.viewMatrix(for: .portrait)
                var mvp = proj * viewM * face.transform
                if let posBuf = pos.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) {
                    enc.setRenderPipelineState(maskPipeline)
                    enc.setDepthStencilState(depthState)
                    enc.setCullMode(.none)
                    enc.setVertexBuffer(posBuf, offset: 0, index: 0)
                    enc.setVertexBuffer(a0Buffer, offset: 0, index: 1)
                    enc.setVertexBuffer(a1Buffer, offset: 0, index: 2)
                    enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 3)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: g.indices.count, indexType: .uint16,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0)
                }
                func uv(_ p: SIMD3<Float>) -> SIMD2<Float> {
                    let c = mvp * SIMD4(p, 1)
                    let ndc = SIMD2(c.x, c.y) / max(c.w, 1e-5)
                    return SIMD2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5)
                }
                let sk = g.skinSamples.map { uv($0.position(faceVerts)) }
                let br = g.browSamples.map { uv($0.position(faceVerts)) }
                u.samples0 = SIMD4(sk[0].x, sk[0].y, sk[1].x, sk[1].y)
                u.samples1 = SIMD4(br[0].x, br[0].y, br[1].x, br[1].y)
                let lv = g.browLevels(landmarks?.result)
                u.brow = SIMD4(lv.alaY, lv.lidTop, lv.browTop, 0)
                u.ref = g.refRegion
                u.sym = settings.tab == .beard ? symRegion : SIMD4(repeating: 0)
                // Around the brow: from under it (above the eyelid) to a little over it, and 6 mm past its end.
                u.browZone = SIMD4(max(g.eyeY + 0.012, lv.browTop - 0.021), lv.browTop + 0.002, 0.006, 0)

                let faceDir = viewM * face.transform * SIMD4<Float>(0, 0, 1, 0)
                let facing = simd_normalize(SIMD3(faceDir.x, faceDir.y, faceDir.z)).z
                frontal = facing > 0.95

                // Learn the person's own landmarks from fairly frontal views.
                if let lm = landmarks, !lm.done, facing > 0.85 {
                    landmarkSnap = LandmarkCalibrator.Snapshot(face: faceVerts, mvp: mvp, size: size)
                }

                // Measure the face shape on relaxed frames, once ARKit has settled on the head shape.
                if let shape, !shape.done, frameIndex % 3 == 0, let since = trackedSince, now - since > 1.5 {
                    let bs = face.blendShapes
                    let jaw = bs[.jawOpen]?.floatValue ?? 1
                    let smile = 0.5 * ((bs[.mouthSmileLeft]?.floatValue ?? 1) + (bs[.mouthSmileRight]?.floatValue ?? 1))
                    if jaw < 0.08, smile < 0.25, let result = shape.add(faceVerts) { settings.faceShape = result }
                }
            }
            enc.endEncoding()
        }

        let counts = countBuffers.isEmpty ? nil : countBuffers[countIndex]
        countIndex = (countIndex + 1) % max(countBuffers.count, 1)
        if let counts { memset(counts.contents(), 0, counts.length) }

        func encode(_ pipeline: MTLRenderPipelineState, _ p: MTLRenderPassDescriptor, countInto: MTLBuffer?) {
            guard let enc = cb.makeRenderCommandEncoder(descriptor: p) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(cTex, index: 1)
            enc.setFragmentTexture(t0, index: 2)
            enc.setFragmentTexture(t1, index: 3)
            enc.setFragmentTexture(hairMap, index: 4)
            enc.setFragmentBytes(&u, length: MemoryLayout<CompUniforms>.stride, index: 0)
            enc.setFragmentBuffer(countInto ?? dummyCounts, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ---- Pass 2: hair map (+ clean-skin statistics), then its mipmaps --------
        let hp = MTLRenderPassDescriptor()
        hp.colorAttachments[0].texture = hairMap
        hp.colorAttachments[0].loadAction = .dontCare
        hp.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: hp) {
            enc.setRenderPipelineState(hairPipeline)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(cTex, index: 1)
            enc.setFragmentTexture(t0, index: 2)
            enc.setFragmentTexture(t1, index: 3)
            enc.setFragmentBytes(&u, length: MemoryLayout<CompUniforms>.stride, index: 0)
            enc.setFragmentBuffer(counts ?? dummyCounts, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: hairMap)
            blit.endEncoding()
        }

        // ---- Pass 3: camera + preview + guides ---------------------------------
        encode(compPipeline, pass, countInto: counts)

        // Clean, unmirrored camera copy for Vision (landmark learning).
        if let snap = landmarkSnap, let lm = landmarks, let tex = lm.beginCapture(size: size, now: now) {
            let saved = u
            u.hair.w = 1
            u.mode.y = 0
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = tex
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            encode(compPipeline, p, countInto: nil)
            u = saved
            cb.addCompletedHandler { _ in lm.run(snap) }
        }

        // Read this frame's counters once the GPU is done.
        if let counts {
            let tab = settings.tab
            cb.addCompletedHandler { [weak self] _ in
                let p = counts.contents().bindMemory(to: UInt32.self, capacity: Counters.count)
                let c = Array(UnsafeBufferPointer(start: p, count: Counters.count))
                DispatchQueue.main.async { self?.ingest(c, tab: tab, faceOK: faceOK, frontal: frontal, now: now) }
            }
        }

        // Photo of the screen (camera + guides).
        if let completion = captureCompletion {
            captureCompletion = nil
            let tex = drawable.texture
            cb.addCompletedHandler { _ in
                let image = Self.image(from: tex)
                DispatchQueue.main.async { completion(image) }
            }
        }

        cb.present(drawable)
        cb.commit()
    }

    /// Main thread: learn from one frame's counters and publish the live status a few times a second.
    private func ingest(_ c: [UInt32], tab: GroomTab, faceOK: Bool, frontal: Bool, now: CFTimeInterval) {
        if faceOK { analysis.learnSkin(c) }
        if faceOK, frontal, tab == .beard { analysis.addSymmetry(c) } else { analysis.fadeSymmetry() }
        guard now - lastPublish > 0.3, tab == settings.tab else { return }
        lastPublish = now

        func status(_ id: Int, _ name: String, _ zone: Int, limit: Double = 0.02) -> ZoneStatus {
            let total = Double(c[Counters.zones + zone * 2]), hair = Double(c[Counters.zones + zone * 2 + 1])
            return ZoneStatus(id: id, name: name, visible: total > 400, stray: total > 0 ? hair / total : 0, limit: limit)
        }
        let zones: [ZoneStatus]
        if tab == .beard {
            let (lz, rz) = (1, 0)   // ARKit face space: +x is the person's own left
            zones = [status(0, "Αριστερό μάγουλο", lz), status(1, "Δεξί μάγουλο", rz), status(2, "Λαιμός", 2)]
        } else {
            // Around the brows the zone is mostly clean skin plus the brow itself: a few hairs are already a lot.
            zones = [status(3, "Ανάμεσα", 3), status(4, "Γύρω από τα φρύδια", 4, limit: 0.001)]
        }
        if settings.zones != zones { settings.zones = zones }
        let sym = tab == .beard && faceOK ? analysis.symmetry() : nil
        if settings.symmetry != sym { settings.symmetry = sym }
    }

    private static func image(from tex: MTLTexture) -> UIImage? {
        guard let ci = CIImage(mtlTexture: tex, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])?
            .oriented(.downMirrored),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
