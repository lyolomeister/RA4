//  Canvas.metal — Layer 2, the output transform, the geometry and the canvas.
//
//  Ported from the Mac app's `modern_UI/Spektrafilm/Spektrafilm/Canvas/Shaders.metal`
//  (`luma`, `tonePosition`, `layer2Tone` steps 1–5, `spow`, the two CCTF
//  functions, `cam16ucsInto` and `outputTransform` — the last four verbatim).
//  Copied rather than shared so the Mac target is untouched; keep them in step
//  by hand.
//
//  Colour rules, as on the Mac (RFC-018): **ProPhoto RGB is the working
//  space.** The engine's print arrives ROMM-encoded (γ1.8) and Layer 2 grades
//  in those values. The one exit is `outputTransform`, run once per
//  destination with numbers from the engine (`spk_output_transform`): Display
//  P3 for the canvas, sRGB for a JPEG export.
//
//  What the iPad does differently: the canvas runs the transform into Display
//  P3 and tags its layer Display P3 (the Mac tags its layer ROMM and lets
//  ColorSync convert). iOS's colour matching of an arbitrary ROMM layer is not
//  documented; P3 is the space iPad displays are built around, and this keeps
//  the "one conversion" rule while rolling, rather than clipping, colours the
//  display cannot show.

#include <metal_stdlib>
using namespace metal;

// ── Layer 2 ──────────────────────────────────────────────────────────────────

struct Layer2Uniforms {            // must match Adjustments.swift, field for field
    float wbR, wbG, wbB;
    float exposureGain;
    float contrast;
    float brightness;
    float saturation;
    float vibrance;
    float highlights;
    float shadows;
    float blackPoint;
    float whitePoint;
    // Encoded mid-grey (linear 0.18) in the working space: pow(0.18, 1/1.8).
    float midGrey;
    uint enabled;
};

static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// Where an encoded value sits between black and white with mid-grey at 0.5
/// (RFC-018 Decision D1). Verbatim from the Mac app.
static inline float tonePosition(float l, float midGrey) {
    float m = saturate(midGrey);
    if (m <= 0.0 || m >= 1.0) m = 0.5;
    return (l <= m) ? 0.5 * l / m : 0.5 + 0.5 * (l - m) / (1.0 - m);
}

/// The Mac app's `layer2Tone` steps 1–5, unchanged, plus vibrance (5b), which
/// the Mac app does not have. Order: white balance → exposure → contrast →
/// brightness → highlights/shadows → black/white point → saturation → vibrance.
static inline float3 layer2Tone(float3 c, constant Layer2Uniforms &u) {
    // 1. white balance (scan-side gains on encoded values)
    c *= float3(u.wbR, u.wbG, u.wbB);
    // 2. exposure in a pseudo-linear domain, then contrast and brightness
    if (u.exposureGain != 1.0) {
        c = pow(max(c, 0.0), 2.2) * u.exposureGain;
        c = pow(c, 1.0 / 2.2);
    }
    if (u.contrast != 0.0) {
        float k = 1.0 + u.contrast * 1.2;
        c = (c - u.midGrey) * k + u.midGrey;      // D1: pivot on mid-grey
    }
    if (u.brightness != 0.0) {
        c = pow(max(c, 0.0), 1.0 / (1.0 + u.brightness * 0.8));
    }
    // 3. highlights / shadows — tone-region masks on luma, from mid-grey (D1)
    float l = tonePosition(luma(c), u.midGrey);
    if (u.shadows != 0.0) {
        float w = (1.0 - l); w = w * w;
        c += u.shadows * 0.25 * w * (1.0 - c);
    }
    if (u.highlights != 0.0) {
        float w = l * l;
        c += u.highlights * 0.25 * w * (u.highlights > 0 ? (1.0 - c) : c);
    }
    // 4. black / white point (the scanner's job)
    c = (c - u.blackPoint) / max(1.0 - u.blackPoint - u.whitePoint, 0.05);
    // 5. saturation
    l = luma(c);
    c = l + (c - l) * u.saturation;
    // 5b. vibrance — saturation weighted towards the colours that have least of
    // it. `s` is the pixel's own chroma, (max − min) / max: 0 for a grey, 1 for
    // a primary. At +1 a grey-ish colour's chroma doubles (as saturation +100
    // would) and a fully saturated one is left alone; at −1 muted colours go
    // grey first. Measured on the same encoded values as step 5.
    if (u.vibrance != 0.0) {
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float s = (mx > 1e-4) ? saturate((mx - mn) / mx) : 0.0;
        float k = max(1.0 + u.vibrance * (1.0 - s), 0.0);
        float lv = luma(c);
        c = lv + (c - lv) * k;
    }
    return c;
}

kernel void layer2(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant Layer2Uniforms &u [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;
    if (u.enabled != 0) c = layer2Tone(c, u);
    dst.write(float4(saturate(c), 1), gid);
}

// ── the output transform (verbatim from the Mac app) ───────────────────────────

struct OutputTransformUniforms {   // must match ColourTransform.swift
    // Source linear RGB → target linear RGB, **row-major**: out[i] = Σ_j m[3i+j]·x[j].
    float matrix[9];
    float cam16M2X[9];
    float cam16M2R[9];
    float cam16K[22];
    uint  sourceCctfMode;
    uint  targetCctfMode;
    uint  cam16Active;
    uint  cam16Lightness;
    uint  cmaxNL;
    uint  cmaxNH;
    uint  _pad0;
    uint  _pad1;
};

inline float spow(float v, float p) {
    float s = v < 0.0f ? -1.0f : (v > 0.0f ? 1.0f : 0.0f);
    return s * pow(fabs(v), p);
}

// Mode order matches `core/colour.cpp`'s `Cctf` enum: 0 sRGB (and Display P3),
// 1 ProPhoto RGB, 2 Adobe RGB (1998), 3 BT.709/BT.2020, 4 identity.
static inline float cctf_decode_mode(float v, uint mode) {
    switch (mode) {
        case 0u: return (0.040449936f >= v) ? v / 12.92f : spow((v + 0.055f) / 1.055f, 2.4f);
        case 1u: return (v < 16.0f * (1.0f / 512.0f)) ? v / 16.0f : pow(v, 1.8f);
        case 2u: return pow(v, 563.0f / 256.0f);
        case 3u: {
            const float alpha = 1.099f, beta = 0.018f;
            const float bp = alpha * pow(beta, 0.45f) - (alpha - 1.0f);
            return (bp > v) ? v / 4.5f : spow((v + (alpha - 1.0f)) / alpha, 1.0f / 0.45f);
        }
        default: return v;
    }
}

static inline float cctf_encode_mode(float v, uint mode) {
    switch (mode) {
        case 0u: return (v <= 0.0031308f) ? 12.92f * v : 1.055f * spow(v, 1.0f / 2.4f) - 0.055f;
        case 1u: return (v < 1.0f / 512.0f) ? v * 16.0f : pow(v, 1.0f / 1.8f);
        case 2u: return pow(v, 256.0f / 563.0f);
        case 3u: {
            const float alpha = 1.099f, beta = 0.018f;
            return (beta > v) ? v * 4.5f : alpha * spow(v, 0.45f) - (alpha - 1.0f);
        }
        default: return v;
    }
}

/// CAM16-UCS gamut compression into the target, per pixel, in linear RGB.
/// Verbatim from the Mac app, which ported it from `engine/src/shaders/gamut.metal`.
static inline float3 cam16ucsInto(float3 rgb, constant OutputTransformUniforms &u,
                                  device const float *cmax, thread bool &moved,
                                  thread bool &outside) {
    const uint nL = u.cmaxNL, nh = u.cmaxNH, lc_active = u.cam16Lightness;
    const float F_L = u.cam16K[0], N_bb = u.cam16K[1], N_cb = u.cam16K[2], n_ = u.cam16K[3],
                z = u.cam16K[4], A_w = u.cam16K[5], c_ = u.cam16K[6], N_c = u.cam16K[7];
    const float L_grid0 = u.cam16K[8], L_grid1 = u.cam16K[9], h_grid0 = u.cam16K[10], h_step = u.cam16K[11];
    const float threshold = u.cam16K[12], limit = u.cam16K[13], power_ = u.cam16K[14];
    const float lc_threshold = u.cam16K[15], lc_limit = u.cam16K[16], lc_power = u.cam16K[17], L_white = u.cam16K[18];
    const float D0 = u.cam16K[19], D1 = u.cam16K[20], D2 = u.cam16K[21];
    const float e_c = pow(1.64f - pow(0.29f, n_), 0.73f);
    const float inv_FL4 = pow(F_L, 0.25f);

    float r = rgb.x, g = rgb.y, b_ = rgb.z;
    float X = u.cam16M2X[0] * r + u.cam16M2X[1] * g + u.cam16M2X[2] * b_;
    float Y = u.cam16M2X[3] * r + u.cam16M2X[4] * g + u.cam16M2X[5] * b_;
    float Z = u.cam16M2X[6] * r + u.cam16M2X[7] * g + u.cam16M2X[8] * b_;
    X *= 100.0f; Y *= 100.0f; Z *= 100.0f;

    float R = 0.401288f * X + 0.650173f * Y - 0.051461f * Z;
    float G = -0.250268f * X + 1.204414f * Y + 0.045854f * Z;
    float B = -0.002079f * X + 0.048952f * Y + 0.953127f * Z;

    float Rc = D0 * R, Gc = D1 * G, Bc = D2 * B;
    float sR = Rc >= 0.0f ? 1.0f : -1.0f, sG = Gc >= 0.0f ? 1.0f : -1.0f, sB = Bc >= 0.0f ? 1.0f : -1.0f;
    float fR = pow(F_L * fabs(Rc) / 100.0f, 0.42f);
    float fG = pow(F_L * fabs(Gc) / 100.0f, 0.42f);
    float fB = pow(F_L * fabs(Bc) / 100.0f, 0.42f);
    float Ra = 400.0f * sR * fR / (27.13f + fR) + 0.1f;
    float Ga = 400.0f * sG * fG / (27.13f + fG) + 0.1f;
    float Ba = 400.0f * sB * fB / (27.13f + fB) + 0.1f;

    float a = Ra - 12.0f * Ga / 11.0f + Ba / 11.0f;
    float bb = (Ra + Ga - 2.0f * Ba) / 9.0f;
    float hrad = atan2(bb, a);
    float e_t = 0.25f * (cos(hrad + 2.0f) + 3.8f);

    float A = (2.0f * Ra + Ga + Ba / 20.0f - 0.305f) * N_bb;
    float Aratio = A / A_w;
    float sJ = Aratio >= 0.0f ? 1.0f : -1.0f;
    float J = 100.0f * sJ * pow(fabs(Aratio), c_ * z);

    float den = Ra + Ga + 21.0f * Ba / 20.0f;
    float t = 0.0f;
    if (den != 0.0f) t = (50000.0f / 13.0f * N_c * N_cb * e_t * sqrt(a * a + bb * bb)) / den;
    float sq = sqrt(fabs(J) / 100.0f);
    float C = (t > 0.0f) ? pow(t, 0.9f) * sq * e_c : 0.0f;
    float M = C * inv_FL4;

    float Mp = (1.0f / 0.0228f) * log(1.0f + 0.0228f * M);
    float Jp = 1.7f * J / (1.0f + 0.007f * J);

    if (lc_active != 0u) {
        float Ln = Jp / L_white;
        if (Ln > lc_threshold) {
            float lsc = lc_limit - lc_threshold;
            float lx = (Ln - lc_threshold) / lsc;
            float ly = lx / pow(1.0f + pow(lx, lc_power), 1.0f / lc_power);
            Ln = lc_threshold + lsc * ly;
        }
        Jp = Ln * L_white;
    }

    float Lc = min(max(Jp, L_grid0), L_grid1);
    float Li = (Lc - L_grid0) / (L_grid1 - L_grid0) * (float)(nL - 1u);
    int l0 = (int)floor(Li); l0 = min(max(l0, 0), (int)nL - 2);
    float lf = Li - (float)l0;
    float hi_ = (hrad - h_grid0) / h_step;
    float hfl = floor(hi_);
    int nhi = (int)nh;
    int h0 = ((int)hfl % nhi + nhi) % nhi;     // Python-style modulo
    int h1 = (h0 + 1) % nhi;
    float hf = hi_ - hfl;
    float c00 = cmax[l0 * nhi + h0], c01 = cmax[l0 * nhi + h1];
    float c10 = cmax[(l0 + 1) * nhi + h0], c11 = cmax[(l0 + 1) * nhi + h1];
    float Cmax = (1.0f - lf) * ((1.0f - hf) * c00 + hf * c01) + lf * ((1.0f - hf) * c10 + hf * c11);
    float safe = Cmax > 1e-9f ? Cmax : 1e-9f;

    float d = Mp / safe;
    moved = d > threshold;
    outside = d > 1.0f;
    if (moved) {
        float sc = limit - threshold;
        float xk = (d - threshold) / sc;
        float yk = xk / pow(1.0f + pow(xk, power_), 1.0f / power_);
        d = threshold + sc * yk;
    }
    float Mp_new = d * safe;

    float M_new = (exp(Mp_new * 0.0228f) - 1.0f) / 0.0228f;
    float J_new = Jp / (1.7f - 0.007f * Jp);
    float C_new = M_new / inv_FL4;

    float sJ2 = J_new >= 0.0f ? 1.0f : -1.0f;
    float A2 = A_w * sJ2 * pow(fabs(J_new) / 100.0f, 1.0f / (c_ * z));
    float sq2 = sqrt(fabs(J_new) / 100.0f);
    float t2 = (sq2 > 0.0f && C_new > 0.0f) ? pow(C_new / (sq2 * e_c), 1.0f / 0.9f) : 0.0f;
    float ca = cos(hrad), sa = sin(hrad);
    float p2 = A2 / N_bb + 0.305f;
    const float p3 = 21.0f / 20.0f;
    float a2, b2;
    if (t2 == 0.0f) { a2 = 0.0f; b2 = 0.0f; }
    else {
        float p1 = ((50000.0f / 13.0f) * N_c * N_cb * e_t) / t2;
        if (fabs(sa) >= fabs(ca)) {
            float p4 = p1 / sa;
            b2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                 (p4 + (2.0f + p3) * (220.0f / 1403.0f) * (ca / sa) - (27.0f / 1403.0f) + p3 * (6300.0f / 1403.0f));
            a2 = b2 * (ca / sa);
        } else {
            float p5 = p1 / ca;
            a2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                 (p5 + (2.0f + p3) * (220.0f / 1403.0f) - ((27.0f / 1403.0f) - p3 * (6300.0f / 1403.0f)) * (sa / ca));
            b2 = a2 * (sa / ca);
        }
    }
    float Ra2 = (460.0f * p2 + 451.0f * a2 + 288.0f * b2) / 1403.0f;
    float Ga2 = (460.0f * p2 - 891.0f * a2 - 261.0f * b2) / 1403.0f;
    float Ba2 = (460.0f * p2 - 220.0f * a2 - 6300.0f * b2) / 1403.0f;

    float vm, sv, base_;
    vm = Ra2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
    base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
    float Rf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D0;
    vm = Ga2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
    base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
    float Gf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D1;
    vm = Ba2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
    base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
    float Bf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D2;

    float Xn = 1.86206786f * Rf - 1.01125463f * Gf + 0.14918677f * Bf;
    float Yn = 0.38752654f * Rf + 0.62144744f * Gf - 0.00897398f * Bf;
    float Zn = -0.01584150f * Rf - 0.03412294f * Gf + 1.04996444f * Bf;
    Xn /= 100.0f; Yn /= 100.0f; Zn /= 100.0f;

    return float3(u.cam16M2R[0] * Xn + u.cam16M2R[1] * Yn + u.cam16M2R[2] * Zn,
                  u.cam16M2R[3] * Xn + u.cam16M2R[4] * Yn + u.cam16M2R[5] * Zn,
                  u.cam16M2R[6] * Xn + u.cam16M2R[7] * Yn + u.cam16M2R[8] * Zn);
}

/// stats[0] the knee acted · stats[1] at the container's limits after encoding ·
/// stats[2] the destination could not hold it (before the knee).
kernel void outputTransform(texture2d<float, access::read>  src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant OutputTransformUniforms &u [[buffer(0)]],
                            device const float *cmax [[buffer(1)]],
                            device atomic_uint *stats [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;

    // 1. the working space's own curve, off
    float3 v = float3(cctf_decode_mode(c.r, u.sourceCctfMode),
                      cctf_decode_mode(c.g, u.sourceCctfMode),
                      cctf_decode_mode(c.b, u.sourceCctfMode));
    // 2. into the target, linearly, chromatically adapted
    float3 lin = float3(u.matrix[0] * v.x + u.matrix[1] * v.y + u.matrix[2] * v.z,
                        u.matrix[3] * v.x + u.matrix[4] * v.y + u.matrix[5] * v.z,
                        u.matrix[6] * v.x + u.matrix[7] * v.y + u.matrix[8] * v.z);
    // 3. CAM16-UCS into the target's gamut, rolling rather than cutting
    bool moved = false, outside = false;
    if (u.cam16Active != 0u) lin = cam16ucsInto(lin, u, cmax, moved, outside);
    // 4. the target's curve, on
    float3 enc = float3(cctf_encode_mode(lin.x, u.targetCctfMode),
                        cctf_encode_mode(lin.y, u.targetCctfMode),
                        cctf_encode_mode(lin.z, u.targetCctfMode));

    if (moved) atomic_fetch_add_explicit(&stats[0], 1u, memory_order_relaxed);
    if (any(enc <= 0.0f) || any(enc >= 1.0f)) atomic_fetch_add_explicit(&stats[1], 1u, memory_order_relaxed);
    if (outside) atomic_fetch_add_explicit(&stats[2], 1u, memory_order_relaxed);

    dst.write(float4(enc, 1.0f), gid);
}

// ── geometry and the canvas (from the Mac app's Shaders.metal) ─────────────────
//
//  `geometryMap`, `editToSource`, `insideCrop` and `geometryResample` are the
//  Mac's, verbatim. `canvasFragment` is the Mac's with its histogram, masks and
//  Digital Intermediate parts left out, and `before` already in Display P3 code
//  values, like `image` after the output transform.

struct GeometryUniform {           // must match Geometry.Uniform in Geometry.swift
    float2 centre;                // crop centre, normalised to the source
    float2 halfExtent;            // crop half-size, normalised
    float2 cosSin;                // the straighten angle
    float2 pixelRatio;            // (w/h, h/w) — the rotation is rigid in pixels
    uint quarterTurns;
    uint flips;                   // bit 0 horizontal, bit 1 vertical
    uint active;
    uint pad;
};

struct CanvasUniforms {           // must match CanvasUniforms in Renderer.swift
    float2 viewportSize;          // in device pixels
    float2 imageSize;             // the *output* size in logical pixels (the source's while cropping)
    float2 offset;                // output origin in device pixels
    float2 pivot;                 // crop tool's edit-space pivot, source-normalised
    float scale;                  // device pixels per output logical pixel
    float surroundGray;           // encoded value of the ground
    float magnification;          // device pixels per *texture* pixel
    float compareSplit;           // split position, 0…1 across the *output*
    uint compare;                 // 0 off, 1 split, 2 before-only
    uint editingCrop;             // show the whole frame, dim outside the crop
    GeometryUniform geometry;
};

//  Output uv → source uv. A transliteration of
//  `Geometry.sourcePoint(forOutput:imageSize:)`.
static inline float2 geometryMap(float2 uv, constant GeometryUniform &g) {
    if (g.active == 0) return uv;
    float2 u = uv;
    if (g.flips & 1u) u.x = 1.0 - u.x;
    if (g.flips & 2u) u.y = 1.0 - u.y;
    switch (g.quarterTurns) {
        case 1: u = float2(u.y, 1.0 - u.x); break;
        case 2: u = float2(1.0 - u.x, 1.0 - u.y); break;
        case 3: u = float2(1.0 - u.y, u.x); break;
        default: break;
    }
    // Crop-local, in units where one unit of x and one of y are the same
    // number of source pixels — otherwise the rotation shears on a
    // non-square frame.
    float px = (u.x - 0.5) * 2.0 * g.halfExtent.x;
    float py = (u.y - 0.5) * 2.0 * g.halfExtent.y * g.pixelRatio.y;
    float rx = px * g.cosSin.x - py * g.cosSin.y;
    float ry = px * g.cosSin.y + py * g.cosSin.x;
    return float2(g.centre.x + rx, g.centre.y + ry * g.pixelRatio.x);
}

//  Edit space → source, while the crop tool is up: the frame stays level on
//  screen and the photograph turns under it, a rotation about the pivot.
//  `Geometry.sourcePoint(forEdit:pivot:imageSize:)`.
static inline float2 editToSource(float2 e, constant CanvasUniforms &u) {
    float dx = e.x - u.pivot.x;
    float dy = (e.y - u.pivot.y) * u.geometry.pixelRatio.y;   // width-fractions
    float rx = dx * u.geometry.cosSin.x - dy * u.geometry.cosSin.y;
    float ry = dx * u.geometry.cosSin.y + dy * u.geometry.cosSin.x;
    return float2(u.pivot.x + rx, u.pivot.y + ry * u.geometry.pixelRatio.x);
}

/// Whether a *source* uv is inside the oriented crop.
static inline bool insideCrop(float2 suv, constant GeometryUniform &g) {
    float dx = suv.x - g.centre.x;
    float dy = (suv.y - g.centre.y) * g.pixelRatio.y;
    float lx =  dx * g.cosSin.x + dy * g.cosSin.y;
    float ly = -dx * g.cosSin.y + dy * g.cosSin.x;
    return abs(lx) <= g.halfExtent.x && abs(ly) <= g.halfExtent.y * g.pixelRatio.y;
}

//  Export's geometry pass: the *same* `geometryMap` the canvas uses, so the
//  file is exactly the part of the frame the canvas shows.
kernel void geometryResample(texture2d<float, access::sample> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant GeometryUniform &g [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::none);
    float2 ouv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(float4(src.sample(lin, geometryMap(ouv, g)).rgb, 1), gid);
}

//  The enlarger transition (EnlargerTransition.swift): on a change of film or
//  paper the old frame turns into its negative, then a warm light sweeps
//  across and the new print develops in behind it. Colours here are Display
//  P3 code values, like everything the canvas draws.
struct EnlargerUniforms {          // must match EnlargerUniforms in EnlargerTransition.swift
    float negative;               // 0…1, how far the old frame is its negative
    float sweep;                  // the light's position across the output, 0…1
    uint kind;                    // 0 colour negative, 1 black-and-white negative, 2 slide
    uint active;
};

/// The film's look of an encoded print colour: dense and brown where the print
/// is light, the orange mask where it is dark; grey for black and white; and a
/// slide, which has no negative, dimmed as on an unlit light table.
static inline float3 enlargerNegative(float3 c, uint kind) {
    if (kind == 2u) return c * 0.28;
    float3 inv = 1.0 - c;
    if (kind == 1u) {
        float y = dot(inv, float3(0.2126, 0.7152, 0.0722));
        return float3(mix(0.07, 0.86, y));
    }
    return mix(float3(0.10, 0.06, 0.045), float3(0.92, 0.57, 0.31), inv);
}

/// `now` is the new print, `was` the frame at the change; `x` runs 0…1 across
/// the output. Ahead of the light, the negative; behind it, the print, pale as
/// fresh paper at first and coming up to full density a little way back.
static inline float3 enlarger(float3 now, float3 was, float x, constant EnlargerUniforms &e) {
    float d = x - e.sweep;                            // > 0: the light has not reached it yet
    float3 c;
    if (d > 0.0) {
        c = mix(was, enlargerNegative(was, e.kind), e.negative);
    } else {
        float developed = smoothstep(0.0, 0.16, -d);
        c = mix(float3(0.93, 0.92, 0.89), now, developed);
    }
    float core = exp(-(d * d) / (0.0045 * 0.0045));
    float halo = exp(-(d * d) / (0.045 * 0.045));
    c += float3(1.0, 0.92, 0.78) * (0.85 * core + 0.3 * halo);
    return min(c, float3(1.0));
}

struct QuadOut { float4 position [[position]]; float2 uv; };

vertex QuadOut canvasVertex(uint vid [[vertex_id]]) {
    // Two triangles covering clip space; uv has (0,0) at top-left.
    float2 pos[6] = { {-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1} };
    QuadOut o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = float2(pos[vid].x * 0.5 + 0.5, 0.5 - pos[vid].y * 0.5);
    return o;
}

// uv (0, 0) is the texture's first row, which is the **top** of the picture
// (the engine writes top row first). No flip anywhere — the Mac app once
// shipped an upside-down print by adding one.
fragment float4 canvasFragment(QuadOut in [[stage_in]],
                               texture2d<float> image [[texture(0)]],
                               texture2d<float> before [[texture(1)]],
                               texture2d<float> from [[texture(2)]],
                               constant CanvasUniforms &u [[buffer(0)]],
                               constant EnlargerUniforms &e [[buffer(1)]])
{
    // Below 100 % the image is minified: linear. At or above, every image
    // pixel covers whole device pixels: nearest, so a 400 % view shows the
    // actual pixels (and grain) instead of a smear.
    constexpr sampler lin(filter::linear, address::clamp_to_edge, mip_filter::none);
    constexpr sampler near(filter::nearest, address::clamp_to_edge, mip_filter::none);
    float2 px = in.uv * u.viewportSize;                    // device pixel, top-left origin
    float2 ip = (px - u.offset) / u.scale;                 // output logical pixel
    float2 ouv = ip / u.imageSize;                         // 0…1 across the output
    float3 ground = float3(u.surroundGray);
    // While the crop is being edited the canvas shows the whole frame, turned
    // under a level crop, and dims what the crop leaves out.
    float2 suv;
    if (u.editingCrop != 0) {
        suv = editToSource(ouv, u);
        if (suv.x < 0.0 || suv.y < 0.0 || suv.x > 1.0 || suv.y > 1.0) {
            return float4(ground, 1);
        }
    } else {
        if (ouv.x < 0.0 || ouv.y < 0.0 || ouv.x > 1.0 || ouv.y > 1.0) {
            return float4(ground, 1);
        }
        suv = geometryMap(ouv, u.geometry);
        if (suv.x < 0.0 || suv.y < 0.0 || suv.x > 1.0 || suv.y > 1.0) {
            return float4(ground, 1);
        }
    }
    //  Before/after. The split is measured across the **output** — the
    //  picture — so the line stays on the same part of the frame when the
    //  view is panned or zoomed, and `before` is sampled through the same
    //  `suv`, so crop, straighten and flips apply to both halves.
    bool useBefore = (u.compare == 2u) ||
                     (u.compare == 1u && ouv.x < u.compareSplit);
    float3 c;
    if (useBefore) {
        c = before.sample(lin, suv).rgb;
    } else {
        c = (u.magnification >= 1.0) ? image.sample(near, suv).rgb : image.sample(lin, suv).rgb;
        if (e.active != 0u) {
            c = enlarger(c, from.sample(lin, suv).rgb, ouv.x, e);
        }
    }
    if (u.editingCrop != 0 && !insideCrop(suv, u.geometry)) {
        c = mix(c, ground, 0.6);
    }
    return float4(c, 1);
}
