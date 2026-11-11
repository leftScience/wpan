#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform float u_mode;
uniform sampler2D u_texture_input;

out vec4 frag_color;

vec3 pq_eotf(vec3 n) {
    n = clamp(n, 0.0, 1.0);
    vec3 np = pow(n, vec3(1.0 / 78.84375));
    vec3 num = max(np - 0.8359375, 0.0);
    vec3 den = 18.8515625 - 18.6875 * np;
    return pow(num / max(den, 1e-6), vec3(1.0 / 0.1593017578125));
}

vec3 hlg_inverse_oetf(vec3 e) {
    e = clamp(e, 0.0, 1.0);
    const float a = 0.17883277;
    const float b = 0.28466892;
    const float c = 0.55991073;
    vec3 low = (e * e) / 3.0;
    vec3 high = (exp((e - c) / a) + b) / 12.0;
    return mix(low, high, step(vec3(0.5), e));
}

vec3 hlg_eotf(vec3 e) {
    vec3 scene = hlg_inverse_oetf(e);
    float ys = max(dot(scene, vec3(0.2627, 0.6780, 0.0593)), 1e-6);
    return scene * pow(ys, 0.2);
}

vec3 bt2020_to_bt709(vec3 c) {
    return vec3(
         1.660491 * c.r - 0.587641 * c.g - 0.072850 * c.b,
        -0.124550 * c.r + 1.132900 * c.g - 0.008349 * c.b,
        -0.018151 * c.r - 0.100579 * c.g + 1.118730 * c.b
    );
}

vec3 hable_Curve(vec3 x) {
    return ((x * (0.15 * x + 0.05) + 0.004) / (x * (0.15 * x + 0.50) + 0.06)) - (0.004 / 0.06);
}

vec3 tone_map_and_finish(vec3 rgb) {
    rgb = max(rgb, 0.0);
    float peak = max(rgb.r, max(rgb.g, rgb.b));
    if (peak > 1e-6) {
        float mapped_peak = hable_Curve(vec3(peak * 2.2)).x / hable_Curve(vec3(6.0)).x;
        mapped_peak = clamp(mapped_peak, 0.0, 1.0);
        rgb *= (mapped_peak / peak);
    }
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    float hi = clamp((peak - 1.2) / 3.0, 0.0, 1.0) * 0.35;
    rgb = mix(rgb, vec3(luma), hi);
    luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = clamp(mix(vec3(luma), rgb, 1.18), 0.0, 1.0);
    return pow(rgb, vec3(1.0 / 2.2));
}

void main() {
    vec2 uv = FlutterFragCoord().xy / max(u_size, vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
#endif
    vec4 color = texture(u_texture_input, uv);
    vec3 rgb;

    if (u_mode > 1.5) {
        // Mode 2: 标准 HDR HLG (BT.2020 HLG -> BT.709 SDR)
        vec3 linear2020 = hlg_eotf(color.rgb);
        rgb = bt2020_to_bt709(linear2020) * 1.8;
    } else if (u_mode > 0.5) {
        // Mode 1: 标准 HDR10 / HDR Vivid / PQ (BT.2020 PQ -> BT.709 SDR)
        vec3 linear2020 = pq_eotf(color.rgb);
        rgb = bt2020_to_bt709(linear2020) * (10000.0 / 100.0);
    } else {
        // Mode 0: 杜比视界 Profile 5 (IPTPQc2 -> BT.709 SDR)
        float R = color.r;
        float G = color.g;
        float B = color.b;
        float Cr = (R - G - 0.1009911 * (B - R)) / 1.8838896;
        float Y  = R - 1.5748 * Cr;
        float Cb = (B - Y) / 1.8556;

        // 杜比视界 Profile 5 RPU 映射多项式还原：
        // 1. 亮度通道 I 采用 RPU 2 阶分段多项式的凹曲线拟合
        // 2. 色度通道 Ct/Cp 在编码时存在非对称偏移（中性灰位于 U≈457, V≈436 而非 512）
        float chroma_gate = smoothstep(0.03, 0.12, Y);
        float I = clamp(0.84 * pow(max(Y - 0.01, 0.0), 0.85), 0.0, 1.0);
        float Ct = clamp(0.0715 * chroma_gate + 1.28 * Cb, -0.5, 0.5);
        float cp_bias = (0.055 + 0.60 * max(Cb, 0.0)) * chroma_gate;
        float Cp = clamp(cp_bias + 1.28 * Cr, -0.5, 0.5);

        // RPU ycc_to_rgb_matrix (IPTPQc2 -> 非线性 LMS_PQ)：
        vec3 lms_pq = vec3(
            I + 0.097534 * Ct + 0.205200 * Cp,
            I - 0.113892 * Ct + 0.133179 * Cp,
            I + 0.032593 * Ct - 0.676880 * Cp
        );

        // PQ EOTF -> 线性 LMS：
        vec3 lms = pq_eotf(lms_pq);

        // RPU rgb_to_lms_matrix 交叉串扰矩阵校正：
        float sum_lms = lms.x + lms.y + lms.z;
        lms = 1.06384 * lms - 0.02130 * vec3(sum_lms);

        // Hunt-Pointer-Estevez LMS -> 线性 BT.709 RGB：
        rgb = vec3(
             5.432622 * lms.x - 4.679100 * lms.y + 0.246257 * lms.z,
            -1.105170 * lms.x + 2.311198 * lms.y - 0.205880 * lms.z,
             0.028104 * lms.x - 0.194660 * lms.y + 1.166325 * lms.z
        );
        rgb *= (10000.0 / 203.0);
    }

    vec3 out_rgb = tone_map_and_finish(rgb);
    frag_color = vec4(out_rgb * color.a, color.a);
}
