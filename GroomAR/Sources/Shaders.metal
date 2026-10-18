#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Pass 1 — the face mesh (plus the neck skirt) rendered into screen-space data:
// every guide is a field on the mesh, so it sticks to the skin and is hidden
// correctly behind the nose/jaw when the head turns (depth test).
// ============================================================================

struct MaskVOut {
    float4 position [[position]];
    float4 a0;
    float4 a1;
};

vertex MaskVOut maskVertex(uint vid [[vertex_id]],
                           const device float3 *positions [[buffer(0)]],
                           const device float4 *a0        [[buffer(1)]],
                           const device float4 *a1        [[buffer(2)]],
                           constant float4x4 &mvp         [[buffer(3)]]) {
    MaskVOut o;
    o.position = mvp * float4(positions[vid], 1.0);
    o.a0 = a0[vid];
    o.a1 = a1[vid];
    return o;
}

struct MaskOut {
    float4 t0 [[color(0)]];
    float4 t1 [[color(1)]];
};

fragment MaskOut maskFragment(MaskVOut in [[stage_in]]) {
    MaskOut o;
    o.t0 = in.a0;
    o.t1 = float4(in.a1.xyz, 1.0);   // w = coverage
    return o;
}

// ============================================================================
// Shared by the hair-map pass and the composite pass.
// ============================================================================

struct CompUniforms {
    float4 dt0;       // inverse display transform a, b, c, d
    float4 dt1;       // tx, ty, viewWidth, viewHeight
    float4 mode;      // x: 0 beard / 1 brows, y: mirror, z: preview on, w: pixel scale
    float4 hair;      // x: strand length (m), y: density, z: darkness, w: 1 = camera only
    float4 samples0;  // skin sample screen uv 0 (xy), 1 (zw)
    float4 samples1;  // brow sample screen uv 0 (xy), 1 (zw)
    float4 brow;      // ala y, lid top y, brow top y, 0
    float4 det;       // hair detector, learned from the person's clean skin: speck lo, speck hi, density lo, density hi
    float4 skin;      // learned skin colour (linear rgb), w = 1 once learned
    float4 ref;       // clean-skin patch on the upper cheeks: |x| min, |x| max, y min, y max (face metres)
    float4 sym;       // symmetry region: |x| min, |x| max, y min, y max (all 0 = off)
    float4 browZone;  // around-the-brow zone: y min, y max, reach past the end line, 0
};

// Counters written every frame (uint32 each). Must match `Counters` in HairAnalysis.swift.
//   0..15    zones: (pixels, hair pixels) x 8
//   16..79   histogram of the hair score on the clean-skin patch (64 bins of 0.002)
//   80..83   clean-skin patch: pixels, sum Y, sum Cb, sum Cr (8 bit)
//   96..287  symmetry profile: side (2) x bin (32, 1 mm of S from -16 mm) x (pixels, sum density, sum darkness)

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

static float2 toCamera(float2 suv, constant CompUniforms &U) {
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

static float3 srgbToLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
static float3 linearToSrgb(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}
static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static float3 cam(float2 screenPoint, texture2d<float> yT, texture2d<float> cT, sampler s, constant CompUniforms &U) {
    float2 c = toCamera(screenPoint, U);
    return srgbToLinear(ycbcrToRGB(yT.sample(s, c).r, cT.sample(s, c).rg));
}

// ============================================================================
// Pass 2 — hair map (half resolution, with mipmaps).
//
// Score of one camera pixel = how much darker it is than BOTH neighbours on opposite sides,
// in the best of four directions and two distances. A hair or a stubble dot is such a valley.
// A shadow edge is not (one of the two neighbours is as dark as the pixel), and neither is
// smooth shading, so shadows under the jaw or on one side of the face do not count as hair.
// The score is a contrast against the local brightness; the small constant keeps sensor noise
// in dark areas from looking like texture.
//
// The same pass measures the person's own clean skin (a patch on the upper cheeks where no beard
// grows): the histogram of the score there is the noise + skin-texture level that the detector
// thresholds are set from, and the mean colour is the skin colour.
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

fragment float4 hairMapFragment(CompOut in [[stage_in]],
                                texture2d<float> yTex [[texture(0)]],
                                texture2d<float> cTex [[texture(1)]],
                                texture2d<float> t0Tex [[texture(2)]],
                                texture2d<float> t1Tex [[texture(3)]],
                                constant CompUniforms &U [[buffer(0)]],
                                device atomic_uint *counts [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 suv = in.screenUV;                 // unmirrored screen space, like the mesh data
    float2 cuv = toCamera(suv, U);
    float v = hairScore(yTex, s, cuv);

    float4 A = t0Tex.sample(s, suv);
    float4 B = t1Tex.sample(s, suv);
    bool face = B.w > 0.99 && (U.mode.x < 0.5 ? A.z < 0.01 : A.w > 0.99);
    float ax = abs(B.x);
    if (face && ax > U.ref.x && ax < U.ref.y && B.y > U.ref.z && B.y < U.ref.w) {
        uint bin = min(63u, uint(v / 0.002));
        float2 cc = cTex.sample(s, cuv).rg;
        atomic_fetch_add_explicit(&counts[16u + bin], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[80], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[81], uint(yTex.sample(s, cuv).r * 255.0 + 0.5), memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[82], uint(cc.x * 255.0 + 0.5), memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[83], uint(cc.y * 255.0 + 0.5), memory_order_relaxed);
    }
    return float4(v, 0.0, 0.0, 1.0);
}

// ============================================================================
// Pass 3 — camera + beard preview + guide lines + "trim here".
// ============================================================================

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

/// Procedural beard hair in face space (metres): strands hang downwards, leaning towards the chin.
static float hairCoverage(float2 c, float len, float density, float px) {
    const float cell = 0.0005;
    float2 g = c / cell;
    float2 base = floor(g);
    int up = int(ceil(len / cell)) + 1;
    float w = max(cell * 0.11, px * 0.45);
    float cov = 0.0;
    for (int dy = -1; dy <= up; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 id = base + float2(dx, dy);
            if (hash21(id) > density) continue;
            float2 root = (id + float2(hash21(id + 3.1), hash21(id + 7.7))) * cell;
            float a = -clamp(root.x / 0.05, -1.0, 1.0) * 0.45 + (hash21(id + 11.3) - 0.5) * 0.6;
            float2 dir = float2(sin(a), -cos(a));
            float L = len * (0.55 + 0.45 * hash21(id + 13.7));
            float2 tip = root + dir * L;
            float2 pa = c - root, ba = tip - root;
            float t = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-14));
            float d = length(pa - ba * t);
            float ww = w * mix(1.0, 0.45, t);
            cov = max(cov, 1.0 - smoothstep(ww * 0.5, ww * 0.5 + px, d));
        }
    }
    return cov;
}

/// Anti-aliased line along the zero of a field, `halfW` in pixels.
static float isoLine(float f, float halfW) {
    float fw = max(fwidth(f), 1e-9);
    float d = abs(f) / fw;
    return 1.0 - smoothstep(halfW - 0.75, halfW + 0.75, d);
}

fragment float4 compositeFragment(CompOut in [[stage_in]],
                                  texture2d<float> yTex [[texture(0)]],
                                  texture2d<float> cTex [[texture(1)]],
                                  texture2d<float> t0Tex [[texture(2)]],
                                  texture2d<float> t1Tex [[texture(3)]],
                                  texture2d<float> hairTex [[texture(4)]],
                                  constant CompUniforms &U [[buffer(0)]],
                                  device atomic_uint *counts [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sm(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 suv = in.screenUV;
    if (U.mode.y > 0.5) suv.x = 1.0 - suv.x;   // selfie mirror
    float3 base = cam(suv, yTex, cTex, s, U);
    if (U.hair.w > 0.5) return float4(linearToSrgb(base), 1.0);   // clean camera copy (for Vision)
    float3 outc = base;
    const float3 trimCol = float3(1.0, 0.25, 0.05);

    float4 A = t0Tex.sample(s, suv);
    float4 B = t1Tex.sample(s, suv);
    float cover = B.w;
    float scale = U.mode.w;

    // The person's skin colour: learned over the cheek patch, or two live samples until then.
    float3 skin = U.skin.w > 0.5 ? U.skin.rgb
        : 0.5 * (cam(U.samples0.xy, yTex, cTex, s, U) + cam(U.samples0.zw, yTex, cTex, s, U));
    skin = max(skin, float3(0.004));
    float skinL = max(luma(skin), 0.02);
    float3 skinChroma = skin / skinL;
    float3 brow = 0.5 * (cam(U.samples1.xy, yTex, cTex, s, U) + cam(U.samples1.zw, yTex, cTex, s, U));
    float browL = max(luma(brow), 1e-3);
    float3 hairCol = brow / browL * min(browL, 0.05);
    float L = luma(base);
    float darkness = saturate(1.0 - L / skinL);

    // Hair cues: single hairs and stubble dots (per pixel), and areas of hair (~3 mm average).
    float v0 = hairTex.sample(sm, suv, level(0.0)).r;
    float vd = hairTex.sample(sm, suv, level(3.0)).r;
    float speck = smoothstep(U.det.x, U.det.y, v0);
    float dense = smoothstep(U.det.z, U.det.w, vd);
    float dark = smoothstep(0.45, 0.65, darkness);   // much darker than the skin: thick dark hair

    float3 lineCol = float3(0.25, 0.85, 1.0);

    if (U.mode.x < 0.5) {
        // ------------------------------------------------------------ Beard
        float S = A.x, lip = A.y, isNeck = A.z, growth = A.w * cover;
        float keep = growth * (1.0 - smoothstep(-0.0006, 0.0006, S));
        float shave = growth * smoothstep(-0.0006, 0.0006, S);

        if (U.mode.z > 0.5) {
            // Clean-shave preview: only pixels that are darker than the skin (hair) are pulled
            // towards the person's own skin; everything else keeps its own colour and texture.
            // On the neck it acts only in a band just below the neckline.
            float hairness = smoothstep(0.10, 0.40, darkness);
            float3 clean = skinChroma * mix(L, skinL * 0.9, hairness);
            float neckBand = isNeck > 0.5 ? 1.0 - smoothstep(0.008, 0.016, S) : 1.0;
            outc = mix(outc, clean, saturate(shave * hairness * neckBand * 0.85));

            // Beard preview: a little extra density plus fine strands in the person's own hair colour.
            if (keep > 0.01 && U.hair.y > 0.0) {
                float px = length(fwidth(B.xy));
                float density = U.hair.y * (isNeck > 0.5 ? 0.5 : 1.0);
                float cov = hairCoverage(B.xy, U.hair.x, density, px);
                outc = mix(outc, outc * 0.88, keep * density * 0.3);
                float3 strand = hairCol * (0.6 + 0.6 * saturate(L / skinL));
                outc = mix(outc, strand, saturate(cov * keep * U.hair.z));
            }
        }

        // "Trim here": hair still growing in the shave zones, highlighted live and counted per zone
        // (0 = face -x side, 1 = face +x side, 2 = neck) for the status in the panel.
        // The area cue is an average over ~3 mm, so it starts a little away from the cutting line
        // (the kept beard would bleed into it). Plain darkness is not used on the neck: it is shadow there.
        float neckBandZ = isNeck > 0.5 ? 1.0 - smoothstep(0.008, 0.016, S) : 1.0;
        float zoneW = shave * neckBandZ * (1.0 - lip);
        if (zoneW > 0.02) {
            float area = dense * smoothstep(0.0012, 0.0025, S);
            float hair = max(speck, max(area, isNeck > 0.5 ? 0.0 : dark));
            if (U.mode.z < 0.5) outc = mix(outc, trimCol, saturate(hair * zoneW * 0.8));
            if (zoneW > 0.5) {
                uint zone = isNeck > 0.5 ? 2u : (B.x < 0.0 ? 0u : 1u);
                atomic_fetch_add_explicit(&counts[zone * 2u], 1u, memory_order_relaxed);
                if (hair > 0.5) atomic_fetch_add_explicit(&counts[zone * 2u + 1u], 1u, memory_order_relaxed);
            }
        }

        // Symmetry: how much hair there is at each distance from the guide, per side of the face.
        // The app finds the real edge of the beard on each side from these two profiles.
        if (U.sym.y > 0.0 && isNeck < 0.5 && cover > 0.99 && abs(S) < 0.016) {
            float ax = abs(B.x);
            if (ax > U.sym.x && ax < U.sym.y && B.y > U.sym.z && B.y < U.sym.w) {
                uint side = B.x < 0.0 ? 0u : 1u;
                uint bin = min(31u, uint((S + 0.016) / 0.001));
                uint i = 96u + (side * 32u + bin) * 3u;
                atomic_fetch_add_explicit(&counts[i], 1u, memory_order_relaxed);
                atomic_fetch_add_explicit(&counts[i + 1u], uint(saturate(vd / 0.128) * 255.0), memory_order_relaxed);
                atomic_fetch_add_explicit(&counts[i + 2u], uint(darkness * 255.0), memory_order_relaxed);
            }
        }

        // Cutting line = edge of the beard, drawn where beard can grow.
        float show = smoothstep(0.2, 0.5, A.w) * cover * (1.0 - lip);
        float dash = isNeck > 0.5 ? step(0.5, fract(B.x / 0.004)) : 1.0;
        float outline = isoLine(S, 2.6 * scale) * show;
        float lineM = isoLine(S, 1.4 * scale) * show * dash;
        outc = mix(outc, float3(0.0), outline * 0.45 * dash);
        outc = mix(outc, srgbToLinear(lineCol), lineM);
    } else {
        // ------------------------------------------------------------ Brows
        float y = B.y;
        float onFace = step(0.5, A.w) * cover;
        float solid = step(U.brow.y, y) * step(y, U.brow.z);
        float dashed = step(U.brow.x, y) * step(y, U.brow.y) * step(0.5, fract(y / 0.0025));
        float3 cols[3] = { float3(0.20, 0.85, 0.40), float3(1.0, 0.84, 0.04), float3(1.0, 0.33, 0.33) };

        // Zone between the brows: light tint, plus live "pluck here" on the hairs still there (zone 3).
        float zoneW = B.z * cover;
        outc = mix(outc, srgbToLinear(float3(1.0, 0.3, 0.3)), zoneW * 0.18);
        if (zoneW > 0.02) {
            float hair = max(speck, max(dense, dark));
            outc = mix(outc, trimCol, saturate(hair * zoneW * 0.85));
            if (zoneW > 0.5) {
                atomic_fetch_add_explicit(&counts[6], 1u, memory_order_relaxed);
                if (hair > 0.5) atomic_fetch_add_explicit(&counts[7], 1u, memory_order_relaxed);
            }
        }

        // Around the brow (zone 4). The brow itself is the dense patch of hair, wherever it is on this
        // person; what gets marked is single hairs away from it (under and over the brow), and
        // any hair past the end line.
        float around = (1.0 - smoothstep(-0.0015, 0.0, A.x))
            * smoothstep(-U.browZone.z - 0.0015, -U.browZone.z, A.z)
            * smoothstep(U.browZone.x, U.browZone.x + 0.002, y)
            * (1.0 - smoothstep(U.browZone.y, U.browZone.y + 0.002, y)) * onFace;
        if (around > 0.02) {
            float body = smoothstep(U.det.z * 0.7, U.det.w * 0.7, vd);
            float pastEnd = 1.0 - smoothstep(-0.0015, 0.0, A.z);
            float hair = max(speck * (1.0 - body), max(speck, body) * pastEnd);
            outc = mix(outc, trimCol, saturate(hair * around * 0.85));
            if (around > 0.5) {
                atomic_fetch_add_explicit(&counts[8], 1u, memory_order_relaxed);
                if (hair > 0.5) atomic_fetch_add_explicit(&counts[9], 1u, memory_order_relaxed);
            }
        }

        for (int k = 0; k < 3; k++) {
            float f = A[k];
            float wSolid = isoLine(f, 1.6 * scale) * solid;
            float wDash = isoLine(f, 0.9 * scale) * dashed * 0.8;
            float outline = isoLine(f, 2.8 * scale) * solid;
            float m = max(wSolid, wDash) * cover;
            outc = mix(outc, float3(0.0), outline * cover * 0.45);
            outc = mix(outc, srgbToLinear(cols[k]), m);
        }
    }

    return float4(linearToSrgb(outc), 1.0);
}
