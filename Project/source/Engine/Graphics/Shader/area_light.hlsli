/**
 * @brief エリアライトGPU構造体
 */
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
    uint ALpadding[3];
};

// ============================================================================
// LTC (Linearly Transformed Cosines) Implementation
// Based on "Real-Time Polygonal-Light Shading with Linearly Transformed Cosines"
// by Eric Heitz et al.
// ============================================================================

static const float PI = 3.14159265359;

/**
 * @brief クランプされたコサインローブの積分を計算
 * @param v1 頂点1
 * @param v2 頂点2
 * @return 積分値
 */
float IntegrateEdge(float3 v1, float3 v2)
{
    float3 v = normalize(v2 - v1);
    float3 n = normalize(cross(v1, v2));
    
    float theta = acos(clamp(dot(normalize(v1), normalize(v2)), -1.0, 1.0));
    float theta_sin = sin(theta);
    
    if (theta_sin < 1e-6)
        return 0.0;
    
    float theta_cos = cos(theta);
    float r1 = length(v1);
    float r2 = length(v2);
    
    float c = dot(n, v);
    float s = sqrt(1.0 - c * c);
    
    return theta_cos * theta_sin / (r1 * r2) * s;
}

/**
 * @brief 多角形の積分を計算
 * @param p 多角形の頂点配列
 * @param n 頂点数
 * @return 積分値
 */
float IntegratePolygon(float3 p[4], int n)
{
    float sum = 0.0;
    
    for (int i = 0; i < n; i++)
    {
        int j = (i + 1) % n;
        sum += IntegrateEdge(p[i], p[j]);
    }
    
    return sum;
}

/**
 * @brief LTCマトリックスを計算（GGX BRDF用の近似）
 * @param roughness 粗さ
 * @param cosTheta 視線と法線の内積
 * @param[out] m マトリックス
 * @param[out] mInv 逆マトリックス
 * @return マトリックスの行列式
 */
float LTC_Matrix_GGX(float roughness, float cosTheta, out float3x3 m, out float3x3 mInv)
{
    // GGX用のLTCマトリックス近似
    float a = max(roughness, 0.001);
    float a2 = a * a;
    
    // 等方性LTCマトリックス
    m = float3x3(
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
    );
    
    // 粗さによるスケーリング
    float scale = 1.0 / max(a2, 0.001);
    m[0][0] = scale;
    m[1][1] = scale;
    
    // 逆マトリックス
    mInv = float3x3(
        a2, 0.0, 0.0,
        0.0, a2, 0.0,
        0.0, 0.0, 1.0
    );
    
    // 行列式
    return a2 * a2;
}

/**
 * @brief LTCによるエリアライトの拡散反射計算
 * @param N サーフェス法線
 * @param V 視線方向
 * @param P サーフェス位置
 * @param light エリアライト
 * @param c_diff 拡散反射色
 * @param f0 フレネルF0
 * @param f90 フレネルF90
 * @return 拡散反射輝度
 */
float3 LTC_Diffuse(float3 N, float3 V, float3 P, AreaLight_GPU light, float3 c_diff, float3 f0, float3 f90)
{
    // ライトのローカル座標系を構築
    float3 lightDir = normalize(light.direction);
    float3 lightRight = normalize(light.right - lightDir * dot(light.right, lightDir));
    float3 lightUp = cross(lightDir, lightRight);
    
    // 矩形の4頂点をワールド座標で計算
    float halfWidth = light.width * 0.5;
    float halfHeight = light.height * 0.5;
    
    float3 p[4];
    p[0] = light.position - halfWidth * lightRight - halfHeight * lightUp;
    p[1] = light.position + halfWidth * lightRight - halfHeight * lightUp;
    p[2] = light.position + halfWidth * lightRight + halfHeight * lightUp;
    p[3] = light.position - halfWidth * lightRight + halfHeight * lightUp;
    
    // ライト座標系へ変換
    float3x3 lightBasis;
    lightBasis[0] = lightRight;
    lightBasis[1] = lightUp;
    lightBasis[2] = lightDir;
    
    for (int i = 0; i < 4; i++)
    {
        p[i] = mul(transpose(lightBasis), p[i] - P);
    }
    
    // 積分計算（拡散用は単位行列を使用）
    float integral = IntegratePolygon(p, 4);
    
    // BRDFの拡散項（Lambertian）
    float NoV = saturate(dot(N, V));
    float3 F = f0 + (f90 - f0) * pow(1.0 - NoV, 5.0);
    float3 brdf_diff = (1.0 - F) * (c_diff / PI);
    
    // 拡散反射の計算
    float3 diff = light.color * light.intensity * integral * brdf_diff;
    
    return diff;
}

/**
 * @brief LTCによるエリアライトの鏡面反射計算
 * @param N サーフェス法線
 * @param V 視線方向
 * @param P サーフェス位置
 * @param light エリアライト
 * @param roughness 粗さ
 * @param f0 フレネルF0
 * @param f90 フレネルF90
 * @return 鏡面反射輝度
 */
float3 LTC_Specular(float3 N, float3 V, float3 P, AreaLight_GPU light, float roughness, float3 f0, float3 f90)
{
    float NoV = saturate(dot(N, V));
    
    // LTCマトリックスの計算
    float3x3 M, Minv;
    float det = LTC_Matrix_GGX(roughness, NoV, M, Minv);
    
    // ライトのローカル座標系を構築
    float3 lightDir = normalize(light.direction);
    float3 lightRight = normalize(light.right - lightDir * dot(light.right, lightDir));
    float3 lightUp = cross(lightDir, lightRight);
    
    // 矩形の4頂点をワールド座標で計算
    float halfWidth = light.width * 0.5;
    float halfHeight = light.height * 0.5;
    
    float3 p[4];
    p[0] = light.position - halfWidth * lightRight - halfHeight * lightUp;
    p[1] = light.position + halfWidth * lightRight - halfHeight * lightUp;
    p[2] = light.position + halfWidth * lightRight + halfHeight * lightUp;
    p[3] = light.position - halfWidth * lightRight + halfHeight * lightUp;
    
    // ライト座標系へ変換
    float3x3 lightBasis;
    lightBasis[0] = lightRight;
    lightBasis[1] = lightUp;
    lightBasis[2] = lightDir;
    
    for (int i = 0; i < 4; i++)
    {
        float3 local = mul(transpose(lightBasis), p[i] - P);
        p[i] = mul(M, local);
    }
    
    // 積分計算
    float integral = IntegratePolygon(p, 4);
    
    // フレネル項の計算
    float3 F = f0 + (f90 - f0) * pow(1.0 - NoV, 5.0);
    
    // LTCのスケーリング係数（BRDFの積分値）
    float ltc_scale = 1.0 / PI;
    
    // 鏡面反射の計算
    float3 spec = light.color * light.intensity * integral * F * det * ltc_scale;
    
    return spec;
}
