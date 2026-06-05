#include "common.hlsli"

#define LTC_LUT_SIZE 64

//=============================================================================
// Area Light
//=============================================================================
struct AreaLight_GPU
{
    float3 position;
    float width;

    float3 direction;
    float height;

    float3 right;
    float intensity;

    float3 color;
    float padding;
};

StructuredBuffer<AreaLight_GPU> areaLights : register(t9);

cbuffer CB_AreaLightCount : register(b7)
{
    uint numAreaLights;
    uint pad0;
    uint pad1;
    uint pad2;
};

//-----------------------------------------------------------------------------
// Sphere Edge Integral
//-----------------------------------------------------------------------------
float IntegrateEdge(float3 v1, float3 v2)
{
    float x = clamp(dot(v1, v2), -0.9999, 0.9999);
    float y = abs(x);

    float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
    float b = 3.4175940 + (4.1616724 + y) * y;

    float theta = (x > 0)
        ? (a / b)
        : (0.5 * rsqrt(max(1.0 - x * x, 1e-6)) - a / b);

    // 接空間における法線方向（Z軸）への射影
    return cross(v1, v2).z * theta;
}

//-----------------------------------------------------------------------------
// Polygon Integral
//-----------------------------------------------------------------------------
float IntegratePolygon(float3 p[4])
{
    [unroll]
    for (int i = 0; i < 4; i++)
    {
        float len = length(p[i]);
        if (len < 1e-6)
            return 0.0;
        p[i] /= len;
    }

    float sum = 0.0;

    [unroll]
    for (int i = 0; i < 4; i++)
    {
        sum += IntegrateEdge(p[i], p[(i + 1) & 3]);
    }

    return max(sum, 0.0);
}

//-----------------------------------------------------------------------------
// Basis
//-----------------------------------------------------------------------------
float3x3 BuildBasis(float3 N, float3 V)
{
    float3 T = V - N * dot(V, N);

    if (dot(T, T) < 1e-6)
    {
        T = abs(N.z) < 0.99
            ? cross(float3(0, 0, 1), N)
            : cross(float3(1, 0, 0), N);
    }
    T = normalize(T);

    float3 B = normalize(cross(N, T));

    // 【修正】transposeを削除
    // 行ベクトルとして T, B, N を格納。
    // これにより、mul(basis, vector) が「ワールド空間から接空間への変換」になります。
    return float3x3(T, B, N);
}

//-----------------------------------------------------------------------------
// LTC Approximation (Textureless)
//-----------------------------------------------------------------------------
float3x3 LTC_MatrixInv(float roughness, float NoV)
{
    // 微小なラフネスによる数値的不安定（NaN）を防ぐ
    roughness = max(roughness, 0.04);

    // テクスチャ（LUT）を使わない簡易フィッティング
    // ラフネスが小さいほど、LTC空間を大きくストレッチさせてハイライトを絞る
    float r2 = roughness * roughness;
    float stretchX = 1.0 / r2;
    float stretchY = 1.0 / roughness;

    // 本来はビュー依存の傾き（M13成分など）が必要ですが、
    // テクスチャなしの対角行列で近似するため、対称性を保ちつつ構築します。
    return float3x3(
        stretchX, 0.0, 0.0,
        0.0, stretchY, 0.0,
        0.0, 0.0, 1.0
    );
}

//-----------------------------------------------------------------------------
// Evaluate
//-----------------------------------------------------------------------------
float LTC_Evaluate(
    float3 N,
    float3 V,
    float3 P,
    AreaLight_GPU light,
    float3x3 Minv)
{
    // direction は照射方向なので反転して面法線化
    float3 D = normalize(-light.direction);

    // ライト裏面除外
    float facing = dot(D, normalize(P - light.position));
    if (facing <= 0)
        return 0.0;

    // right を面へ射影
    float3 R = normalize(light.right - D * dot(light.right, D));
    float3 U = normalize(cross(R, D));

    float hw = light.width * 0.5;
    float hh = light.height * 0.5;

    float3 p[4];
    p[0] = light.position - R * hw - U * hh;
    p[1] = light.position + R * hw - U * hh;
    p[2] = light.position + R * hw + U * hh;
    p[3] = light.position - R * hw + U * hh;

    float3x3 basis = BuildBasis(N, V);

    [unroll]
    for (int i = 0; i < 4; i++)
    {
        p[i] -= P;
        p[i] = mul(basis, p[i]); // ワールド空間から接空間へ変換
        p[i] = mul(Minv, p[i]); // 接空間からLTC空間へ変換
    }

    // 【修正】「* area」を削除
    // 多角形積分（立体角）の段階ですでにライトのサイズ（hw, hh）が反映されているため、
    // ここで面積をかけると二重計算になります。
    return IntegratePolygon(p);
}

//-----------------------------------------------------------------------------
// Diffuse
//-----------------------------------------------------------------------------
float3 LTC_Diffuse(
    float3 N,
    float3 V,
    float3 P,
    AreaLight_GPU light,
    float3 c_diff,
    float3 f0,
    float3 f90)
{
    float integral = LTC_Evaluate(
        N, V, P, light,
        float3x3(
            1, 0, 0,
            0, 1, 0,
            0, 0, 1
        )
    );

    // 元の実装の数式バランス（/ PI）を維持
    return light.color * light.intensity * integral * c_diff / PI;
}

//-----------------------------------------------------------------------------
// Specular
//-----------------------------------------------------------------------------
float3 LTC_Specular(
    float3 N,
    float3 V,
    float3 P,
    AreaLight_GPU light,
    float roughness,
    float3 f0,
    float3 f90)
{
    float NoV = saturate(dot(N, V));

    float3x3 Minv = LTC_MatrixInv(roughness, NoV);

    float integral = LTC_Evaluate(N, V, P, light, Minv);

    // シェーディングの破綻を防ぐため、一般論的なSchlickの近似
    float3 F = f0 + (f90 - f0) * pow(1.0 - NoV, 5.0);

    return light.color * light.intensity * integral * F;
}