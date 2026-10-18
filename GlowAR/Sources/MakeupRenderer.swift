import ARKit
import CoreImage
import MetalKit
import UIKit

final class MakeupRenderer: NSObject, MTKViewDelegate {
    let session = ARSession()
    private let settings: MakeupSettings
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let maskPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let analysisPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var textureCache: CVMetalTextureCache?
    private let ciContext: CIContext

    private var regionTex: MTLTexture?
    private var faceUVTex: MTLTexture?
    private var depthTex: MTLTexture?
    private var xyTex: MTLTexture?        // neutral-face position and skin-care weight per pixel
    private var analysisMap: MTLTexture?  // hair score and camera colour per pixel, with mipmaps

    private let inFlight = DispatchSemaphore(value: 3)
    private var positionBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private var weightBuffer: MTLBuffer?
    private var uvBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var regions: FaceRegions?
    private var lips: LipCalibrator?

    // Skin care, brow guide and face measurements.
    private var neutralGeometry: ARFaceGeometry?
    private var neutralBuffer: MTLBuffer?   // neutral position (xyz) + skin-care weight (w) per vertex
    private var geometry: FaceGeometry?
    private var toneVertices: [Int] = []
    private var landmarks: LandmarkCalibrator?
    private var measure: FaceMeasure?
    private let analysis = SkinAnalysis()
    private var appliedBlush = BlushPlacement.standard
    private var countBuffers: [MTLBuffer] = []
    private var countIndex = 0
    private var dummyCounts: MTLBuffer?
    private var lastPublish: CFTimeInterval = 0
    private var trackedSince: CFTimeInterval?
    private var frameIndex = 0

    private var captureRequested = false
    private var captureCompletion: ((UIImage?) -> Void)?
    private let startTime = CACurrentMediaTime()

    init?(view: MTKView, settings: MakeupSettings) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.settings = settings
        self.ciContext = CIContext(mtlDevice: device)

        let maskDesc = MTLRenderPipelineDescriptor()
        maskDesc.vertexFunction = library.makeFunction(name: "maskVertex")
        maskDesc.fragmentFunction = library.makeFunction(name: "maskFragment")
        maskDesc.colorAttachments[0].pixelFormat = .rgba16Float
        maskDesc.colorAttachments[1].pixelFormat = .rgba16Float
        maskDesc.colorAttachments[2].pixelFormat = .rgba16Float
        maskDesc.depthAttachmentPixelFormat = .depth32Float

        let analysisDesc = MTLRenderPipelineDescriptor()
        analysisDesc.vertexFunction = library.makeFunction(name: "compositeVertex")
        analysisDesc.fragmentFunction = library.makeFunction(name: "analysisFragment")
        analysisDesc.colorAttachments[0].pixelFormat = .rgba16Float

        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction = library.makeFunction(name: "compositeVertex")
        compDesc.fragmentFunction = library.makeFunction(name: "compositeFragment")
        compDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true

        do {
            maskPipeline = try device.makeRenderPipelineState(descriptor: maskDesc)
            compositePipeline = try device.makeRenderPipelineState(descriptor: compDesc)
            analysisPipeline = try device.makeRenderPipelineState(descriptor: analysisDesc)
        } catch {
            print("Pipeline error: \(error)")
            return nil
        }
        guard let ds = device.makeDepthStencilState(descriptor: depthDesc) else { return nil }
        depthState = ds
        super.init()

        lips = LipCalibrator(device: device, library: library)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = self

        setupFaceBuffers()
    }

    // MARK: - Session

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            settings.unsupported = true
            return
        }
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.maximumNumberOfTrackedFaces = 1
        // Highest-resolution camera format that still runs at 60 fps.
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        let area: (ARConfiguration.VideoFormat) -> CGFloat = { $0.imageResolution.width * $0.imageResolution.height }
        if let best = formats.filter({ $0.framesPerSecond >= 60 }).max(by: { area($0) < area($1) })
            ?? formats.max(by: { area($0) < area($1) }) {
            config.videoFormat = best
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() { session.pause() }

    private func setupFaceBuffers() {
        guard ARFaceTrackingConfiguration.isSupported,
              let neutral = ARFaceGeometry(blendShapes: [:]) else { return }
        guard let regions = FaceRegions.build(from: neutral) else {
            settings.regionsFailed = true
            return
        }
        self.regions = regions
        neutralGeometry = neutral
        let verts = neutral.vertices
        var skin = [Float](repeating: 0, count: verts.count)
        if let g = FaceGeometry(neutral) {
            geometry = g
            toneVertices = g.toneVertices
            skin = g.skinWeights(lips: regions.weights.map { $0.x })
            landmarks = LandmarkCalibrator(device: device, geometry: g)
            measure = FaceMeasure(geometry: g)
        }
        let neutral4 = verts.indices.map { SIMD4<Float>(verts[$0], skin[$0]) }
        neutralBuffer = neutral4.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        let countBytes = Counters.count * MemoryLayout<UInt32>.stride
        countBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: countBytes, options: .storageModeShared) }
        dummyCounts = device.makeBuffer(length: countBytes, options: .storageModeShared)
        let n = verts.count
        let indices = neutral.triangleIndices
        indexCount = indices.count
        indexBuffer = indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        uvBuffer = neutral.textureCoordinates.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        weightBuffer = regions.weights.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        let posLen = MemoryLayout<SIMD3<Float>>.stride * n
        positionBuffers = (0..<3).compactMap { _ in device.makeBuffer(length: posLen, options: .storageModeShared) }
    }

    // MARK: - Capture

    func requestCapture(_ completion: @escaping (UIImage?) -> Void) {
        captureCompletion = completion
        captureRequested = true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        makeTargets(size)
    }

    private func makeTargets(_ size: CGSize) {
        let w = max(Int(size.width), 1), h = max(Int(size.height), 1)
        func tex(_ fmt: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        regionTex = tex(.rgba16Float, [.renderTarget, .shaderRead])
        faceUVTex = tex(.rgba16Float, [.renderTarget, .shaderRead])
        depthTex = tex(.depth32Float, [.renderTarget])
        xyTex = tex(.rgba16Float, [.renderTarget, .shaderRead])
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(w / 2, 1),
                                                          height: max(h / 2, 1), mipmapped: true)
        md.usage = [.renderTarget, .shaderRead]
        md.storageMode = .private
        analysisMap = device.makeTexture(descriptor: md)
    }

    /// Moves the blush to the placement chosen for the face shape (weights are rebuilt once).
    private func updateBlushPlacementIfNeeded() {
        let wanted = settings.blushPlacement
        guard wanted != appliedBlush, let neutral = neutralGeometry,
              let r = FaceRegions.build(from: neutral, blush: wanted) else { return }
        appliedBlush = wanted
        regions = r
        weightBuffer = r.weights.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
    }

    private func cameraTexture(_ pb: CVPixelBuffer, _ fmt: MTLPixelFormat, _ plane: Int) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var tex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, plane, &tex)
        return status == kCVReturnSuccess ? tex : nil
    }

    func draw(in view: MTKView) {
        guard let frame = session.currentFrame,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor else { return }
        let size = view.drawableSize
        if regionTex == nil || regionTex!.width != Int(size.width) || regionTex!.height != Int(size.height) {
            makeTargets(size)
        }
        guard let regionTex, let faceUVTex, let depthTex, let xyTex, let analysisMap else { return }
        updateBlushPlacementIfNeeded()

        let pb = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              let yRef = cameraTexture(pb, .r8Unorm, 0),
              let cRef = cameraTexture(pb, .rg8Unorm, 1),
              let yTex = CVMetalTextureGetTexture(yRef),
              let cTex = CVMetalTextureGetTexture(cRef) else { return }

        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        cb.addCompletedHandler { [weak self] _ in
            _ = yRef; _ = cRef   // keep camera textures alive until the GPU is done
            self?.inFlight.signal()
        }

        // ---- Face tracking -------------------------------------------------------
        let face = frame.anchors.lazy.compactMap { $0 as? ARFaceAnchor }.first
        let faceOK = (face?.isTracked ?? false) && regions != nil && !positionBuffers.isEmpty
        if faceOK != settings.faceVisible { settings.faceVisible = faceOK }

        var uniforms = CompositeUniforms()
        let perEye = FaceRegions.linerPointsPerEye + 1
        var linerPoints = [SIMD4<Float>](repeating: .zero, count: 2 * perEye)
        var linerCount = 0
        var visionSnap: LipCalibrator.Snapshot?
        var landmarkSnap: LandmarkCalibrator.Snapshot?
        let browsOn = settings.selected == .brows
        let now0 = CACurrentMediaTime()
        frameIndex += 1
        if !faceOK { trackedSince = nil } else if trackedSince == nil { trackedSince = now0 }
        if landmarks?.collect() == true {
            let p = Double(landmarks?.progress ?? 0)
            if p != settings.browCalibration { settings.browCalibration = p }
        }
        if settings.remeasureRequested {
            settings.remeasureRequested = false
            measure?.reset()
            analysis.resetMeasurements()
        }

        // ---- Pass 1: region masks ---------------------------------------------
        let maskPass = MTLRenderPassDescriptor()
        for (i, t) in [regionTex, faceUVTex, xyTex].enumerated() {
            maskPass.colorAttachments[i].texture = t
            maskPass.colorAttachments[i].loadAction = .clear
            maskPass.colorAttachments[i].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            maskPass.colorAttachments[i].storeAction = .store
        }
        maskPass.depthAttachment.texture = depthTex
        maskPass.depthAttachment.loadAction = .clear
        maskPass.depthAttachment.clearDepth = 1
        maskPass.depthAttachment.storeAction = .dontCare

        if let enc = cb.makeRenderCommandEncoder(descriptor: maskPass) {
            if faceOK, let face, let regions, let weightBuffer, let uvBuffer, let indexBuffer, let neutralBuffer {
                let verts = face.geometry.vertices
                bufferIndex = (bufferIndex + 1) % positionBuffers.count
                let posBuf = positionBuffers[bufferIndex]
                verts.withUnsafeBytes { src in
                    posBuf.contents().copyMemory(from: src.baseAddress!, byteCount: min(src.count, posBuf.length))
                }
                let proj = frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.001, zFar: 10)
                let viewM = frame.camera.viewMatrix(for: .portrait)
                var mvp = proj * viewM * face.transform

                enc.setRenderPipelineState(maskPipeline)
                enc.setDepthStencilState(depthState)
                enc.setCullMode(.none)
                enc.setVertexBuffer(posBuf, offset: 0, index: 0)
                enc.setVertexBuffer(weightBuffer, offset: 0, index: 1)
                enc.setVertexBuffer(uvBuffer, offset: 0, index: 2)
                enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 3)
                enc.setVertexBuffer(neutralBuffer, offset: 0, index: 4)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)

                // Screen-space helpers computed with the very same matrix.
                let sizeV = SIMD2(Float(size.width), Float(size.height))
                func project(_ v: SIMD3<Float>) -> SIMD2<Float> {
                    let c = mvp * SIMD4<Float>(v, 1)
                    let ndc = SIMD2<Float>(c.x, c.y) / max(c.w, 1e-5)
                    return SIMD2<Float>((ndc.x * 0.5 + 0.5) * sizeV.x, (0.5 - ndc.y * 0.5) * sizeV.y)
                }
                // Screen pixels per metre at the depth of the face (true scale, whatever the head pose).
                let depth = max((mvp * SIMD4<Float>(0, 0, 0, 1)).w, 0.05)
                let ppm = abs(proj.columns.0.x) * sizeV.x * 0.5 / depth
                uniforms.view.x = ppm

                let skin = regions.skinSampleVertices.map { project(verts[$0]) / sizeV }
                if skin.count == 2 {
                    uniforms.params1 = SIMD4(skin[0].x, skin[0].y, skin[1].x, skin[1].y)
                }
                let lipPts = regions.lipSampleVertices.map { project(verts[$0]) / sizeV }
                if lipPts.count == 6 {
                    uniforms.lipS0 = SIMD4(lipPts[0].x, lipPts[0].y, lipPts[1].x, lipPts[1].y)
                    uniforms.lipS1 = SIMD4(lipPts[2].x, lipPts[2].y, lipPts[3].x, lipPts[3].y)
                    uniforms.lipS2 = SIMD4(lipPts[4].x, lipPts[4].y, lipPts[5].x, lipPts[5].y)
                }
                let faceDir = viewM * face.transform * SIMD4<Float>(0, 0, 1, 0)
                uniforms.params3 = SIMD4(simd_normalize(SIMD3(faceDir.x, faceDir.y, faceDir.z)), 0)

                // Learn the real lip outline only from fairly frontal views.
                if uniforms.params3.z > 0.8, !regions.lipSampleVertices.isEmpty {
                    let mc = regions.lipSampleVertices.map { project(verts[$0]) }
                        .reduce(SIMD2<Float>.zero, +) / Float(regions.lipSampleVertices.count)
                    visionSnap = LipCalibrator.Snapshot(positions: verts, mvp: mvp, size: size, mouthCenter: mc)
                }

                if let g = geometry {
                    // Brow guide: lines through the person's own nose sides and pupils once learned.
                    let personal = landmarks?.result
                    let lv = g.browLevels(personal)
                    let lines = g.browLines(personal)
                    uniforms.ref = g.refRegion
                    uniforms.browBox = g.browBox(personal)
                    uniforms.browA = lines.ala
                    uniforms.browN0 = lines.normals[0]
                    uniforms.browN1 = lines.normals[1]
                    uniforms.browN2 = lines.normals[2]
                    uniforms.brow = SIMD4(lv.alaY, lv.lidTop, lv.browTop, browsOn ? 1 : 0)
                    uniforms.browB = g.aroundBrowZone(personal)
                    uniforms.face = SIMD4(g.eyeX, g.eyeY, g.eyeToMouth, g.mouthCenter.y)
                    if toneVertices.count == 2 {
                        let t0 = project(verts[toneVertices[0]]) / sizeV, t1 = project(verts[toneVertices[1]]) / sizeV
                        uniforms.tone = SIMD4(t0.x, t0.y, t1.x, t1.y)
                    }

                    // The person's own nose sides, pupils and brow height: learned once, from frontal frames.
                    if let lm = landmarks, !lm.done, uniforms.params3.z > 0.85 {
                        landmarkSnap = LandmarkCalibrator.Snapshot(face: verts, mvp: mvp, size: size)
                    }
                    // Face proportions, on relaxed frames, once ARKit has settled on the head shape.
                    if let measure, measure.result == nil, frameIndex % 3 == 0, let since = trackedSince, now0 - since > 1.5 {
                        let bs = face.blendShapes
                        let jaw = bs[.jawOpen]?.floatValue ?? 1
                        let smile = 0.5 * ((bs[.mouthSmileLeft]?.floatValue ?? 1) + (bs[.mouthSmileRight]?.floatValue ?? 1))
                        if jaw < 0.08, smile < 0.25 { measure.add(verts) }
                    }
                }

                if settings.linerShade != nil {
                    for (e, eye) in [regions.leftEye, regions.rightEye].enumerated() {
                        let pts = FaceRegions.linerPolyline(eye: eye, verts: verts, thickness: Float(settings.linerThickness),
                                                            wing: Float(settings.linerWing), pixelsPerMetre: ppm, project: project)
                        for (k, p) in pts.prefix(perEye).enumerated() { linerPoints[e * perEye + k] = p }
                    }
                    linerCount = perEye
                }
            }
            enc.endEncoding()
        }

        // ---- Uniforms ----------------------------------------------------------
        let t = frame.displayTransform(for: .portrait, viewportSize: size).inverted()
        uniforms.dt0 = SIMD4(Float(t.a), Float(t.b), Float(t.c), Float(t.d))
        uniforms.dt1 = SIMD4(Float(t.tx), Float(t.ty), Float(size.width), Float(size.height))
        uniforms.lip = settings.lipShade.map { SIMD4($0.linear, Float(settings.lipIntensity)) } ?? .zero
        uniforms.shadow = settings.shadowShade.map { SIMD4($0.linear, Float(settings.shadowIntensity)) } ?? .zero
        uniforms.blush = settings.blushShade.map { SIMD4($0.linear, Float(settings.blushIntensity)) } ?? .zero
        uniforms.liner = settings.linerShade.map { SIMD4($0.linear, Float(settings.linerIntensity)) } ?? .zero
        uniforms.params0 = SIMD4(Float(settings.lipFinish.value), Float(settings.shimmer), 1, faceOK ? 1 : 0)
        uniforms.params2 = SIMD4(Float(linerCount), Float(CACurrentMediaTime() - startTime),
                                 settings.debugMasks ? 1 : 0, 0)
        uniforms.params3.w = 0   // keep the camera direction as it comes (no mirroring)
        uniforms.params2.w = lips?.calibration ?? 0
        uniforms.det = analysis.det
        uniforms.skinFx = SIMD4(Float(settings.smoothing), Float(settings.evenTone), Float(settings.glow), Float(settings.contour))
        uniforms.view.y = settings.splitOn ? Float(settings.split) : -1

        // ---- Analysis map (+ clean-skin and brow statistics), then its mipmaps ----
        let counts = countBuffers.isEmpty ? nil : countBuffers[countIndex]
        countIndex = (countIndex + 1) % max(countBuffers.count, 1)
        if let counts { memset(counts.contents(), 0, counts.length) }
        let mapPass = MTLRenderPassDescriptor()
        mapPass.colorAttachments[0].texture = analysisMap
        mapPass.colorAttachments[0].loadAction = .dontCare
        mapPass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: mapPass) {
            enc.setRenderPipelineState(analysisPipeline)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(xyTex, index: 1)
            enc.setFragmentTexture(cTex, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            enc.setFragmentBuffer(counts ?? dummyCounts, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: analysisMap)
            blit.endEncoding()
        }

        // ---- Lip learning: paint the latest Vision outline into the UV lip map --
        if let lips, let weightBuffer, let uvBuffer, let indexBuffer {
            lips.encodePaint(cb, weights: weightBuffer, uvs: uvBuffer, indices: indexBuffer, indexCount: indexCount)
        }

        func encodeComposite(_ pass: MTLRenderPassDescriptor, countInto: MTLBuffer? = nil) {
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(cTex, index: 1)
            enc.setFragmentTexture(regionTex, index: 2)
            enc.setFragmentTexture(faceUVTex, index: 3)
            enc.setFragmentTexture(lips?.lipUVTex, index: 4)
            enc.setFragmentTexture(xyTex, index: 5)
            enc.setFragmentTexture(analysisMap, index: 6)
            enc.setFragmentBuffer(countInto ?? dummyCounts, offset: 0, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            linerPoints.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        /// The same frame into an offscreen texture, with some uniforms changed for that one pass.
        func encodeOffscreen(_ tex: MTLTexture, _ change: (inout CompositeUniforms) -> Void) {
            let saved = uniforms
            change(&uniforms)
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = tex
            p.colorAttachments[0].loadAction = .dontCare
            p.colorAttachments[0].storeAction = .store
            encodeComposite(p)
            uniforms = saved
        }

        // ---- Pass 2: composite to screen ---------------------------------------
        encodeComposite(passDesc, countInto: counts)

        // ---- Upright, untouched camera copy for Vision (lip outline), when Vision is free --
        if let snap = visionSnap, let lips, let vtex = lips.beginCapture(drawableSize: size, now: CACurrentMediaTime()) {
            encodeOffscreen(vtex) { $0.params0.z = 0 }
            cb.addCompletedHandler { _ in lips.runVision(snap) }
        }

        // ---- Same for the brow landmarks (nose sides, pupils, brow height), until learned --
        if let snap = landmarkSnap, let lm = landmarks, let tex = lm.beginCapture(size: size, now: now0) {
            encodeOffscreen(tex) { $0.params0.z = 0 }
            cb.addCompletedHandler { _ in lm.run(snap) }
        }

        // ---- Read this frame's counters once the GPU is done ----------------------
        if let counts, faceOK {
            cb.addCompletedHandler { [weak self] _ in
                let p = counts.contents().bindMemory(to: UInt32.self, capacity: Counters.count)
                let c = Array(UnsafeBufferPointer(start: p, count: Counters.count))
                DispatchQueue.main.async { self?.ingest(c, browsOn: browsOn, now: now0) }
            }
        }

        // ---- Photo: the full look (no split, no brow guide), saved by the caller to Photos --
        if captureRequested, let completion = captureCompletion {
            captureRequested = false
            captureCompletion = nil
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                             height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            if let tex = device.makeTexture(descriptor: d) {
                encodeOffscreen(tex) { $0.view.y = -1; $0.brow.w = 0; $0.params2.z = 0 }
                let ctx = ciContext
                cb.addCompletedHandler { _ in DispatchQueue.global(qos: .utility).async {
                    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                    var image: UIImage?
                    if let ci = CIImage(mtlTexture: tex, options: [.colorSpace: cs])?.oriented(.downMirrored),
                       let cg = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: cs) {
                        image = UIImage(cgImage: cg)
                    }
                    DispatchQueue.main.async { completion(image) }
                } }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }

        cb.present(drawable)
        cb.commit()
    }

    /// Main thread: learn from one frame's counters; publish the brow status and what suits this face.
    private func ingest(_ c: [UInt32], browsOn: Bool, now: CFTimeInterval) {
        analysis.learn(c)
        if settings.profile == nil, !settings.remeasureRequested, let m = measure?.result,
           let contrast = analysis.contrast, let undertone = analysis.undertone {
            settings.setProfile(FaceProfile(length: m.length, jaw: m.jaw, eyeGap: m.eyeGap, eyeTilt: m.eyeTilt,
                                            contrast: contrast, undertone: undertone))
            settings.measureProgress = 1
        }
        guard now - lastPublish > 0.3 else { return }
        lastPublish = now
        if settings.profile == nil {
            let p = Double(min(measure?.progress ?? 0, analysis.progress))
            if abs(p - settings.measureProgress) > 0.01 { settings.measureProgress = p }
        }
        var zones: [BrowZone] = []
        if browsOn {
            func zone(_ id: Int, _ name: String, limit: Double) -> BrowZone {
                let total = Double(c[Counters.zones + id * 2]), hair = Double(c[Counters.zones + id * 2 + 1])
                return BrowZone(id: id, name: name, visible: total > 400, stray: total > 0 ? hair / total : 0, limit: limit)
            }
            // Around the brows the zone is mostly clean skin plus the brow itself: a few hairs are already a lot.
            zones = [zone(3, "Ανάμεσα", limit: 0.02), zone(4, "Γύρω από τα φρύδια", limit: 0.001)]
        }
        if settings.browZones != zones { settings.browZones = zones }
    }
}
