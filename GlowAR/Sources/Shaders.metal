#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Pass 1 — render the tracked face mesh into screen-space region masks.
// ============================================================================

struct MaskVOut {
    float4 position [[position]];
    float4 weights;   // lips, eyeshadow, blush, coverage
    float2 uv;        // face texture coordinate (stable on the skin)
    float3 xys;       // position on the neutral face (x, y in metres) and the skin-care weight
};

vertex MaskVOut maskVertex(uint vid [[vertex_id]],
                           const device float3 *positions [[buffer(0)]],
                           const device float4 *weights   [[buffer(1)]],
                           const device float2 *uvs       [[buffer(2)]],
                           constant float4x4 &mvp         [[buffer(3)]],
                           const device float4 *neutral   [[buffer(4)]]) {
    MaskVOut o;
    o.position = mvp * float4(positions[vid], 1.0);
    o.weights = weights[vid];
    o.uv = uvs[vid];
    o.xys = float3(neutral[vid].xy, neutral[vid].w);
    return o;
}

struct MaskOut {
    float4 regions [[color(0)]];
    float4 faceUV  [[color(1)]];
    float4 faceXY  [[color(2)]];
};

fragment MaskOut maskFragment(MaskVOut in [[stage_in]]) {
    MaskOut o;
    o.regions = in.weights;
    o.faceUV = float4(in.uv, 1.0, 1.0);
    o.faceXY = float4(in.xys, 1.0);
    return o;
}

// ============================================================================
// Lip learning — paint the real lip outline (found by Vision) into the face
// mesh's UV space. Rasterises the mesh in UV space; each texel knows where it
// was on screen when Vision looked, and checks whether that spot was inside
// the lip outline. Blended over many frames into a stable per-person lip map.
// ============================================================================

struct PaintUniforms {
    float4x4 mvp;
    float4 viewSize;  // width, height, polygon point count, 0
    float4 params;    // blend alpha, 0, 0, 0
};

struct PaintVOut {
    float4 position [[position]];
    float2 screenPx;
    float envelope;
};

vertex PaintVOut lipPaintVertex(uint vid [[vertex_id]],
                                const device float3 *positions [[buffer(0)]],
                                const device float4 *weights   [[buffer(1)]],
                                const device float2 *uvs       [[buffer(2)]],
                                constant PaintUniforms &P      [[buffer(3)]]) {
    PaintVOut o;
    float2 uv = uvs[vid];
    o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    float4 c = P.mvp * float4(positions[vid], 1.0);
    float2 ndc = c.xy / max(c.w, 1e-5);
    o.screenPx = float2((ndc.x * 0.5 + 0.5) * P.viewSize.x, (0.5 - ndc.y * 0.5) * P.viewSize.y);
    o.envelope = weights[vid].x;
    return o;
}

/// Signed distance to a closed polygon, positive inside.
static float polygonSD(float2 p, constant float2 *poly, int n) {
    float d = 1e9;
    bool inside = false;
    for (int i = 0, j = n - 1; i < n; j = i, i++) {
        float2 a = poly[j], b = poly[i];
        float2 e = b - a, w = p - a;
        float h = clamp(dot(w, e) / max(dot(e, e), 1e-6), 0.0, 1.0);
        d = min(d, length(w - e * h));
        if ((a.y > p.y) != (b.y > p.y)) {
            float xCross = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y);
            if (p.x < xCross) inside = !inside;
        }
    }
    return inside ? d : -d;
}

fragment float4 lipPaintFragment(PaintVOut in [[stage_in]],
                                 constant PaintUniforms &P [[buffer(0)]],
                                 constant float2 *outer    [[buffer(1)]]) {
    if (in.envelope < 0.01) discard_fragment();
    float sd = polygonSD(in.screenPx, outer, int(P.viewSize.z));
    float m = smoothstep(-1.5, 1.5, sd);
    return float4(m, 0.0, 0.0, P.params.x);
}

// ============================================================================
// Pass 2 — composite makeup onto the real camera pixels.
//
// Pigment model: every camera pixel = surface colour x light. Dividing a lip
// pixel by the person's average lip colour gives the light falling on that
// exact spot (shading, warm/cool cast, lip lines). Multiplying that light by
// the lipstick colour gives what the lipstick would really look like there.
// Shine is handled separately, because reflections are not pigment-coloured.
// ============================================================================

struct CompositeUniforms {
    float4 dt0;      // inverse display transform a, b, c, d
    float4 dt1;      // tx, ty, viewWidth, viewHeight
    float4 lip;      // linear rgb, opacity
    float4 shadow;   // linear rgb, opacity
    float4 blush;    // linear rgb, opacity
    float4 liner;    // linear rgb, opacity
    float4 params0;  // lipFinish (0 matte .. 1 gloss), shimmer, showMakeup, faceOK
    float4 params1;  // skin sample screen uv 0 (xy), uv 1 (zw)
    float4 params2;  // liner points per eye, time, debug, lip calibration (0..1)
    float4 params3;  // face direction in camera space (xyz), mirror flag
    float4 lipS0;    // lip sample screen uvs (6 points)
    float4 lipS1;
    float4 lipS2;
    float4 det;      // hair detector, learned from the person's clean skin: speck lo, speck hi, density lo, density hi
    float4 ref;      // clean-skin patch on the upper cheeks: |x| min, |x| max, y min, y max (face metres)
    float4 browBox;  // area that holds the brows: |x| min, |x| max, y min, y max
    float4 browA;    // side of the nose where the brow lines start: -x side (xy), +x side (zw)
    float4 browN0;   // start line normal: -x side (xy), +x side (zw); normals point towards the nose
    float4 browN1;   // arch line normal
    float4 browN2;   // end line normal
    float4 brow;     // ala y, lid top y, brow top y, 1 = show the brow guide
    float4 browB;    // around-the-brow zone: y min, y max, reach past the end line; w = eye line y
    float4 skinFx;   // skin: smoothing, even tone, glow, contour (0..1 each)
    float4 view;     // screen pixels per metre on the face; before/after split (screen x, < 0 = off)
    float4 face;     // neutral face, metres: |x| of the eye centres, eye line y, eye-to-mouth height, mouth y
    float4 tone;     // skin sample screen uvs on the forehead (xy) and the chin (zw), for the even-tone target
};

// Counters written every frame (uint32 each). Must match `Counters` in SkinAnalysis.swift.
//   0..15    zones: (pixels, hair pixels) x 8; zone 3 = between the brows, zone 4 = around them
//   16..79   histogram of the hair score on the clean-skin patch (64 bins of 0.002)
//   80..83   clean-skin patch: pixels, sums of luma, Cb, Cr (8 bit)
//   96..127  histogram of luma over the brow area (32 bins)

struct CompOut {
    float4 position [[position]];
    float2 screenUV;
};

vertex CompOut compositeVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    CompOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.screenUV = float2(p.x, 1.0 - p.y);
    return o;
}

static float2 toCamera(float2 suv, constant CompositeUniforms &U) {
    return float2(U.dt0.x * suv.x + U.dt0.z * suv.y + U.dt1.x,
                  U.dt0.y * suv.x + U.dt0.w * suv.y + U.dt1.y);
}

static float3 ycbcrToRGB(float y, float2 cbcr) {
    const float4x4 m = float4x4(float4(+1.0000, +1.0000, +1.0000, 0.0),
                                float4(+0.0000, -0.3441, +1.7720, 0.0),
                                float4(+1.4020, -0.7141, +0.0000, 0.0),
                                float4(-0.7010, +0.5291, -0.8860, 1.0));
    return saturate((m * float4(y, cbcr, 1.0)).rgb);
}

static float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static float3 linearToSrgb(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// Bring an out-of-range colour back into [0,1] by desaturating, not clipping.
static float3 fitGamut(float3 r) {
    float l = clamp(luma(r), 0.0, 0.98);
    float mx = max(r.r, max(r.g, r.b));
    if (mx > 1.0) {
        r = mix(float3(l), r, (1.0 - l) / max(mx - l, 1e-4));
    }
    return max(r, 0.0);
}

/// Learned lip map, looked up through the face UV at a screen point.
static float learnedLip(float2 p, texture2d<float> faceUVTex, texture2d<float> lipUVTex,
                        sampler nearestS, sampler linearS) {
    float4 f = faceUVTex.sample(nearestS, p);
    if (f.z < 0.5) return 0.0;
    return lipUVTex.sample(linearS, f.xy).r;
}

// ============================================================================
// Analysis map (half resolution, with mipmaps): r = hair score, gba = Y, Cb, Cr.
//
// Hair score of one camera pixel = how much darker it is than BOTH neighbours on opposite sides,
// in the best of four directions and two distances. A hair is such a valley; a shadow edge
// (one neighbour as dark as the pixel) and smooth shading are not. The score is a contrast
// against the local brightness; the small constant keeps sensor noise in dark areas down.
//
// The colour channels and their mipmaps give the camera image averaged over larger and larger
// areas, which the skin smoothing uses.
//
// The same pass measures the person's own clean skin (a patch on the upper cheeks): the
// histogram of the score there is the noise + skin-texture level that the detector thresholds
// are set from, and its mean colour gives the undertone. It also collects how dark the brow
// area is, for the recommendations.
// ============================================================================

static float hairScore(texture2d<float> yTex, sampler s, float2 cuv) {
    float2 tx = 1.0 / float2(yTex.get_width(), yTex.get_height());
    float c = yTex.sample(s, cuv).r;
    const float2 dirs[4] = { float2(1.0, 0.0), float2(0.7071, 0.7071), float2(0.0, 1.0), float2(-0.7071, 0.7071) };
    float best = 0.0, sum = c;
    for (int k = 0; k < 4; k++) {
        float2 o = dirs[k] * tx;
        float a1 = yTex.sample(s, cuv + o * 2.0).r, b1 = yTex.sample(s, cuv - o * 2.0).r;
        float a2 = yTex.sample(s, cuv + o * 4.0).r, b2 = yTex.sample(s, cuv - o * 4.0).r;
        best = max(best, max(min(a1, b1), min(a2, b2)) - c);
        sum += a1 + b1;
    }
    return best / (sum / 9.0 + 0.2);
}

fragment float4 analysisFragment(CompOut in [[stage_in]],
                                 texture2d<float> yTex    [[texture(0)]],
                                 texture2d<float> xyTex   [[texture(1)]],
                                 texture2d<float> cbcrTex [[texture(2)]],
                                 constant CompositeUniforms &U [[buffer(0)]],
                                 device atomic_uint *counts    [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 suv = in.screenUV;
    float2 cuv = toCamera(suv, U);
    float v = hairScore(yTex, s, cuv);
    float yv = yTex.sample(s, cuv).r;
    float2 cv = cbcrTex.sample(s, cuv).rg;

    float4 X = xyTex.sample(s, suv);
    if (X.w > 0.99) {
        float ax = abs(X.x);
        if (ax > U.ref.x && ax < U.ref.y && X.y > U.ref.z && X.y < U.ref.w) {
            uint bin = min(63u, uint(v / 0.002));
            atomic_fetch_add_explicit(&counts[16u + bin], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&counts[80], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&counts[81], uint(yv * 255.0 + 0.5), memory_order_relaxed);
            atomic_fetch_add_explicit(&counts[82], uint(cv.x * 255.0 + 0.5), memory_order_relaxed);
            atomic_fetch_add_explicit(&counts[83], uint(cv.y * 255.0 + 0.5), memory_order_relaxed);
        }
        if (ax > U.browBox.x && ax < U.browBox.y && X.y > U.browBox.z && X.y < U.browBox.w) {
            atomic_fetch_add_explicit(&counts[96u + min(31u, uint(yv * 32.0))], 1u, memory_order_relaxed);
        }
    }
    return float4(v, yv, cv);
}

/// Anti-aliased line along the zero of a distance field (metres); `mpp` = metres per pixel there.
static float isoLine(float f, float mpp, float halfW) {
    float d = abs(f) / max(mpp, 1e-7);
    return 1.0 - smoothstep(halfW - 0.75, halfW + 0.75, d);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float segmentCoverage(float2 px, float4 a, float4 b) {
    float2 pa = px - a.xy, ba = b.xy - a.xy;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-4));
    float d = length(pa - ba * h);
    float th = mix(a.z, b.z, h);
    return 1.0 - smoothstep(th - 0.8, th + 0.8, d);
}

/// Soft elliptical spot: 1 at the centre, `r` = radii along and across an axis tilted by `tilt`.
static float spot(float2 d, float2 r, float tilt) {
    float c = cos(tilt), sn = sin(tilt);
    float2 p = float2(c * d.x + sn * d.y, -sn * d.x + c * d.y) / r;
    return exp(-1.4 * dot(p, p));
}

/// Where highlighter (x) and contour (y) go, on the neutral face. F = U.face.
///  Highlighter: top of the cheekbones up towards the temples, the bridge of the nose, the cupid's bow.
///  Contour: the hollow under the cheekbones (from the ear towards the mouth corner) and the sides of the nose.
static float2 glowContour(float2 q, float4 F) {
    float ex = F.x, ey = F.y, h = F.z, my = F.w;
    float2 a = float2(abs(q.x), q.y);
    float along = smoothstep(ey - 0.40 * h, ey - 0.28 * h, q.y) * (1.0 - smoothstep(ey - 0.12 * h, ey + 0.02 * h, q.y));
    float glow = spot(a - float2(1.42 * ex, ey - 0.27 * h), float2(0.25, 0.095) * h, 0.45);
    glow = max(glow, 0.8 * exp(-q.x * q.x / (2.0 * 0.0028 * 0.0028)) * along);
    glow = max(glow, 0.7 * spot(q - float2(0.0, my + 0.19 * h), float2(0.0055, 0.0028), 0.0));
    float contour = spot(a - float2(1.63 * ex, ey - 0.71 * h), float2(0.28, 0.10) * h, 0.57);
    float sd = a.x - 0.23 * ex;
    contour = max(contour, 0.45 * exp(-sd * sd / (2.0 * 0.002 * 0.002)) * along);
    return float2(glow, contour);
}

fragment float4 compositeFragment(CompOut in [[stage_in]],
                                  texture2d<float> yTex      [[texture(0)]],
                                  texture2d<float> cbcrTex   [[texture(1)]],
                                  texture2d<float> regionTex [[texture(2)]],
                                  texture2d<float> faceUVTex [[texture(3)]],
                                  texture2d<float> lipUVTex  [[texture(4)]],
                                  texture2d<float> xyTex     [[texture(5)]],
                                  texture2d<float> mapTex    [[texture(6)]],
                                  constant CompositeUniforms &U [[buffer(0)]],
                                  constant float4 *linerPts     [[buffer(1)]],
                                  device atomic_uint *counts    [[buffer(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sn(filter::nearest, address::clamp_to_edge);
    constexpr sampler sm(filter::linear, mip_filter::linear, address::clamp_to_edge);

    bool mirror = U.params3.w > 0.5;
    float2 suv = in.screenUV;
    if (mirror) suv.x = 1.0 - suv.x;
    float2 cuv = toCamera(suv, U);
    float yv = yTex.sample(s, cuv).r;
    float2 cv = cbcrTex.sample(s, cuv).rg;
    float3 base = srgbToLinear(ycbcrToRGB(yv, cv));

    // Left of the before/after split the camera stays untouched.
    bool show = U.params0.z > 0.5 && U.params0.w > 0.5 && in.screenUV.x >= U.view.y;
    if (!show) {
        return float4(linearToSrgb(base), 1.0);
    }

    float4 reg = regionTex.sample(s, suv);

    // Neutral-face position and skin-care weight of this pixel (the target is cleared to zero,
    // so divide by the coverage to undo the blend at the edge of the face).
    float4 X = xyTex.sample(s, suv);
    float cover = X.w;
    float2 q = X.xy / max(cover, 1e-3);
    float onFace = smoothstep(0.5, 1.0, cover);
    float skinW = saturate(X.z / max(cover, 1e-3)) * onFace;
    float ppm = max(U.view.x, 500.0);

    // Person's own skin, read live from both cheeks (averaged over ~3 mm).
    float4 m0 = mapTex.sample(sm, U.params1.xy, level(3.0));
    float4 m1 = mapTex.sample(sm, U.params1.zw, level(3.0));
    float skinY = 0.5 * (m0.g + m1.g);
    float2 skinC = 0.5 * (m0.ba + m1.ba);
    float3 skinMean = max(srgbToLinear(ycbcrToRGB(skinY, skinC)), float3(0.004));
    float skinL = max(luma(skinMean), 0.02);
    float3 skinChroma = skinMean / skinL;

    // ---------------------------------------------------------------- Skin
    // Smoothing by frequency bands: M = the skin averaged over ~5 mm, but only over neighbours
    // of similar colour (so brows, lids, nostrils and the edge of the face stay sharp);
    // S = averaged over ~1 mm. What lies between them (blemishes, blotches, fine lines) is
    // taken out; most of what is finer than S (pores, real skin texture) stays, so the skin
    // does not turn to plastic. "Even tone" pulls the local skin colour towards the person's
    // own average colour (less redness), without touching light and shade.
    if (skinW > 0.01 && (U.skinFx.x > 0.0 || U.skinFx.y > 0.0)) {
        float2 px = 1.0 / max(U.dt1.zw, float2(1.0));
        float lodS = max(log2(0.0010 * ppm * 0.5), 0.0);
        float lodL = lodS + 1.3;
        float3 B = float3(yv, cv);
        float3 S = mapTex.sample(sm, suv, level(lodS)).gba;
        const float2 ring[14] = {
            float2(1.0, 0.0), float2(0.5, 0.866), float2(-0.5, 0.866), float2(-1.0, 0.0), float2(-0.5, -0.866), float2(0.5, -0.866),
            float2(0.924, 0.383), float2(0.383, 0.924), float2(-0.383, 0.924), float2(-0.924, 0.383),
            float2(-0.924, -0.383), float2(-0.383, -0.924), float2(0.383, -0.924), float2(0.924, -0.383) };
        // Neighbours are compared with S, the fine average at this very pixel: next to a brow or a lid
        // S is still pure skin, so the darker neighbours across the edge are left out.
        float3 acc = S;
        float wsum = 1.0;
        for (int k = 0; k < 14; k++) {
            bool innerRing = k < 6;
            float2 o = ring[k] * (innerRing ? 0.0025 : 0.0050) * ppm * px;
            float3 t = mapTex.sample(sm, suv + o, level(innerRing ? lodL : lodL + 0.5)).gba;
            float3 d = t - S;
            float w = exp(-d.x * d.x / (2.0 * 0.08 * 0.08) - dot(d.yz, d.yz) / (2.0 * 0.022 * 0.022));
            acc += t * w;
            wsum += w;
        }
        float3 M = acc / wsum;
        float hairy = smoothstep(U.det.z, U.det.w * 2.0, mapTex.sample(sm, suv, level(3.0)).r);
        float a = U.skinFx.x * skinW * (1.0 - hairy);
        float3 mid = S - M, high = B - S;
        float3 v = B - a * float3(mid.x + 0.35 * high.x, mid.yz + 0.6 * high.yz);
        // Even-tone target: the average skin colour over both cheeks, the forehead and the chin. The last
        // two count only where they look like the cheeks, so a fringe or a shadow does not pull it.
        float4 m2 = mapTex.sample(sm, U.tone.xy, level(3.0));
        float4 m3 = mapTex.sample(sm, U.tone.zw, level(3.0));
        float w2 = (1.0 - smoothstep(0.03, 0.05, length(m2.ba - skinC))) * step(0.6 * skinY, m2.g);
        float w3 = (1.0 - smoothstep(0.03, 0.05, length(m3.ba - skinC))) * step(0.6 * skinY, m3.g);
        float2 toneC = (2.0 * skinC + w2 * m2.ba + w3 * m3.ba) / (2.0 + w2 + w3);
        float2 dC = M.yz - toneC;
        float nearSkin = 1.0 - smoothstep(0.035, 0.07, length(dC));
        v.yz -= U.skinFx.y * 0.7 * skinW * nearSkin * dC;
        yv = v.x;
        cv = v.yz;
        base = srgbToLinear(ycbcrToRGB(yv, cv));
    }

    float L = luma(base);
    float3 outc = base;

    float2 ytexel = 1.0 / float2(yTex.get_width(), yTex.get_height());
    float lipDebug = 0.0;

    // ---------------------------------------------------------------- Lips
    if (U.lip.a > 0.0) {
        // Close the thin seam between the lips (mesh opening) without growing the outer edge:
        // a pixel is filled only if there is lip both above and below it.
        float2 stx = 1.0 / max(U.dt1.zw, float2(1.0));
        float up = 0.0, dn = 0.0, upL = 0.0, dnL = 0.0;
        for (int k = 1; k <= 3; k++) {
            float2 o = float2(0.0, stx.y * 2.5 * float(k));
            up = max(up, regionTex.sample(s, suv - o).r);
            dn = max(dn, regionTex.sample(s, suv + o).r);
            upL = max(upL, learnedLip(suv - o, faceUVTex, lipUVTex, sn, s));
            dnL = max(dnL, learnedLip(suv + o, faceUVTex, lipUVTex, sn, s));
        }
        float lipW = max(reg.r, min(up, dn));
        float learned = max(learnedLip(suv, faceUVTex, lipUVTex, sn, s), min(upL, dnL));
        float calib = U.params2.w;

        if (lipW > 0.002 || learned > 0.002) {
            float2 texel = 1.0 / float2(cbcrTex.get_width(), cbcrTex.get_height());
            float2 cc = float2(0.0);
            for (int k = 0; k < 8; k++) {
                float a = float(k) * 0.785398;
                cc += cbcrTex.sample(s, cuv + texel * 1.6 * float2(cos(a), sin(a))).rg;
            }
            cc *= 0.125;

            // This person's lip colour, from six points on the lips.
            float2 lipPts[6] = { U.lipS0.xy, U.lipS0.zw, U.lipS1.xy, U.lipS1.zw, U.lipS2.xy, U.lipS2.zw };
            float2 lipCC = float2(0.0);
            float lipY = 0.0;
            float3 lipMean = float3(0.0);
            for (int k = 0; k < 6; k++) {
                float2 p = toCamera(lipPts[k], U);
                float2 pc = cbcrTex.sample(s, p).rg;
                float py = yTex.sample(s, p).r;
                lipCC += pc;
                lipY += py;
                lipMean += srgbToLinear(ycbcrToRGB(py, pc));
            }
            lipCC /= 6.0;
            lipY /= 6.0;
            lipMean = max(lipMean / 6.0, float3(0.004));

            // Fallback mask until the real outline is learned: face geometry + colour classification.
            const float3 fw = float3(1.0, 1.0, 0.25);
            float3 pf = float3(cc, yv) * fw;
            float3 lipF = float3(lipCC, lipY) * fw;
            float3 skinF = float3(skinC, skinY) * fw;
            float dl = length(pf - lipF), ds = length(pf - skinF);
            float pLip = smoothstep(-0.15, 0.35, (ds - dl) / (ds + dl + 1e-4));
            float conf = smoothstep(0.008, 0.03, length(lipF - skinF));
            pLip = mix(smoothstep(0.4, 0.9, lipW), pLip, conf);
            float core = smoothstep(0.6, 0.9, lipW);
            float band = smoothstep(0.02, 0.3, lipW);
            float mGeo = smoothstep(0.15, 0.85, max(core, band * pLip));

            // Learned real outline (crisp).
            float mLearn = smoothstep(0.25, 0.75, learned);
            float m = mix(mGeo, mLearn, calib);

            // Keep teeth clean when the mouth opens.
            float rel = L / skinL;
            float teeth = smoothstep(0.9, 1.35, rel) * (1.0 - smoothstep(0.015, 0.045, cc.y - 0.5));
            m *= 1.0 - 0.9 * teeth;
            lipDebug = m;

            // Highlights = brighter than the neighbourhood (the shine on the lips).
            float localY = 0.0;
            for (int k = 0; k < 8; k++) {
                float a = float(k) * 0.785398 + 0.39;
                localY += yTex.sample(s, cuv + ytexel * 6.0 * float2(cos(a), sin(a))).r;
            }
            float localL = srgbToLinear(float3(localY * 0.125)).x;
            float shine = max(L - localL, 0.0);

            // Light reaching this pixel = (pixel minus its shine) / lip surface colour (~0.2 albedo).
            float3 lipAlbedo = lipMean / max(luma(lipMean), 1e-4) * 0.20;
            float3 light = base * saturate((L - shine) / max(L, 1e-4)) / lipAlbedo;
            float3 pigment = U.lip.rgb * light;

            // Shine on top of the pigment, by finish: matte barely, satin some, gloss strong.
            float finish = U.params0.x;
            float shineAmt = mix(0.15, 1.0, smoothstep(0.0, 0.5, finish)) + 1.2 * smoothstep(0.5, 1.0, finish);
            pigment += shine * shineAmt * float3(1.0, 0.97, 0.95);

            outc = mix(outc, fitGamut(pigment), saturate(m * U.lip.a));
        }
    }

    // ----------------------------------------------------------- Eyeshadow
    if (reg.g > 0.002 && U.shadow.a > 0.0) {
        // Same pigment model, using the skin as the reference surface (~0.30 albedo).
        float3 light = base / (skinChroma * 0.30);
        float3 rec = fitGamut(U.shadow.rgb * light);

        // Glitter that catches the light as the head turns (anchored to the skin).
        float2 g = faceUVTex.sample(s, suv).xy * 380.0;
        float2 cell = floor(g);
        float h = hash21(cell);
        float3 facet = normalize(float3(hash21(cell + 17.0) - 0.5, hash21(cell + 41.0) - 0.5, 1.4));
        float glint = pow(saturate(dot(facet, normalize(U.params3.xyz))), 90.0);
        float dotShape = 1.0 - smoothstep(0.05, 0.45, length(fract(g) - 0.5));
        float sparkle = step(0.6, h) * dotShape * glint;
        rec += U.params0.y * sparkle * (0.35 + L) * float3(1.0, 0.95, 0.85) * 1.4;

        outc = mix(outc, rec, saturate(reg.g * U.shadow.a));
    }

    // --------------------------------------------------------------- Blush
    if (reg.b > 0.002 && U.blush.a > 0.0) {
        float3 c = U.blush.rgb;
        float lc = max(luma(c), 1e-3);
        // Shift the skin's colour towards the blush tint, keeping its own light and texture.
        float3 tinted = outc * (c / lc) / sqrt(max(skinChroma, float3(0.05)));
        float3 rec = fitGamut(tinted * (luma(outc) / max(luma(tinted), 1e-4)) * mix(1.0, lc / skinL, 0.15));
        outc = mix(outc, rec, saturate(reg.b * U.blush.a * 0.8));
    }

    // ------------------------------------------------- Contour and highlighter
    if (onFace > 0.0 && (U.skinFx.z > 0.0 || U.skinFx.w > 0.0)) {
        float2 gc = glowContour(q, U.face) * onFace;
        // Bronzer: a warm, darker veil that keeps the skin's own light and texture.
        outc = mix(outc, outc * float3(0.66, 0.54, 0.46), saturate(gc.y * U.skinFx.w * 0.75));
        // Highlighter: a pearly pigment that returns more of the light already falling there.
        float lift = gc.x * U.skinFx.z;
        float3 light = outc / (skinChroma * 0.30);
        float3 pearl = fitGamut(float3(1.0, 0.93, 0.85) * 0.50 * light);
        outc = mix(outc, max(outc, pearl), saturate(lift * 0.34));
        outc = fitGamut(outc * (1.0 + 0.12 * lift));
    }

    // ------------------------------------------------------------- Eyeliner
    int count = int(U.params2.x);
    if (count > 1 && U.liner.a > 0.0) {
        float2 px = in.position.xy;
        if (mirror) px.x = U.dt1.z - px.x;
        float cov = 0.0;
        for (int eye = 0; eye < 2; eye++) {
            int b = eye * count;
            for (int i = 0; i < count - 1; i++) {
                cov = max(cov, segmentCoverage(px, linerPts[b + i], linerPts[b + i + 1]));
            }
        }
        float3 c = U.liner.rgb * (0.65 + 0.35 * saturate(L / skinL));
        outc = mix(outc, c, saturate(cov * U.liner.a));
    }

    // ---------------------------------------------------------------- Brows
    // Guide for shaping the brows: three lines from the side of the nose (start, arch, end),
    // the zone between the brows, and the single hairs that fall outside the brow.
    if (U.brow.w > 0.5 && cover > 0.5) {
        float y = q.y;
        float mpp = 1.0 / ppm;
        float scale = U.dt1.z / 400.0;
        bool plus = q.x >= 0.0;
        float2 d = q - (plus ? U.browA.zw : U.browA.xy);
        float f[3] = { dot(d, plus ? U.browN0.zw : U.browN0.xy),
                       dot(d, plus ? U.browN1.zw : U.browN1.xy),
                       dot(d, plus ? U.browN2.zw : U.browN2.xy) };

        // Hair cues: single hairs (per pixel), areas of hair (~3 mm average), plain darkness.
        float v0 = mapTex.sample(sm, suv, level(0.0)).r;
        float vd = mapTex.sample(sm, suv, level(3.0)).r;
        float speck = smoothstep(U.det.x, U.det.y, v0);
        float dense = smoothstep(U.det.z, U.det.w, vd);
        float dark = smoothstep(0.45, 0.65, saturate(1.0 - L / skinL));
        const float3 pluckCol = float3(1.0, 0.25, 0.05);

        // Between the brows (zone 3): light tint, and every hair still there.
        float ey = U.browB.w;
        float between = smoothstep(0.0, 0.0015, f[0]) * smoothstep(ey + 0.008, ey + 0.011, y)
            * (1.0 - smoothstep(ey + 0.028, ey + 0.031, y)) * cover;
        outc = mix(outc, srgbToLinear(float3(1.0, 0.3, 0.3)), between * 0.18);
        if (between > 0.02) {
            float hair = max(speck, max(dense, dark));
            outc = mix(outc, pluckCol, saturate(hair * between * 0.85));
            if (between > 0.5) {
                atomic_fetch_add_explicit(&counts[6], 1u, memory_order_relaxed);
                if (hair > 0.5) atomic_fetch_add_explicit(&counts[7], 1u, memory_order_relaxed);
            }
        }

        // Around the brow (zone 4). The brow itself is the dense patch of hair, wherever it is on this
        // person; what gets marked is single hairs away from it, and any hair past the end line.
        float around = (1.0 - smoothstep(-0.0015, 0.0, f[0]))
            * smoothstep(-U.browB.z - 0.0015, -U.browB.z, f[2])
            * smoothstep(U.browB.x, U.browB.x + 0.002, y)
            * (1.0 - smoothstep(U.browB.y, U.browB.y + 0.002, y)) * cover;
        if (around > 0.02) {
            float body = smoothstep(U.det.z * 0.7, U.det.w * 0.7, vd);
            float pastEnd = 1.0 - smoothstep(-0.0015, 0.0, f[2]);
            float hair = max(speck * (1.0 - body), max(speck, body) * pastEnd);
            outc = mix(outc, pluckCol, saturate(hair * around * 0.85));
            if (around > 0.5) {
                atomic_fetch_add_explicit(&counts[8], 1u, memory_order_relaxed);
                if (hair > 0.5) atomic_fetch_add_explicit(&counts[9], 1u, memory_order_relaxed);
            }
        }

        // The three lines: solid over the brow, dashed from the nose up to the eyelid.
        float solid = step(U.brow.y, y) * step(y, U.brow.z);
        float dashed = step(U.brow.x, y) * step(y, U.brow.y) * step(0.5, fract(y / 0.0025));
        float3 cols[3] = { float3(0.20, 0.85, 0.40), float3(1.0, 0.84, 0.04), float3(1.0, 0.33, 0.33) };
        for (int k = 0; k < 3; k++) {
            float wSolid = isoLine(f[k], mpp, 1.15 * scale) * solid;
            float wDash = isoLine(f[k], mpp, 0.8 * scale) * dashed * 0.8;
            float outline = isoLine(f[k], mpp, 2.0 * scale) * solid;
            outc = mix(outc, float3(0.0), outline * cover * 0.45);
            outc = mix(outc, srgbToLinear(cols[k]), max(wSolid, wDash) * cover);
        }
    }

    if (U.params2.z > 0.5) {
        outc = mix(outc, float3(lipDebug, reg.g, reg.b), 0.55);
    }

    return float4(linearToSrgb(outc), 1.0);
}
