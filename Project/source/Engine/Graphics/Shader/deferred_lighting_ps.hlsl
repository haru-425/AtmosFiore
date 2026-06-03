#include "fullscreen_quad.hlsli"
#include "samplers.hlsli"
#include "constants.hlsli"
#include "bidirectional_reflectance_distribution_function.hlsli"
#include "point_light.hlsli"
#include "point_shadow.hlsli"
#include "spot_light.hlsli"
#include "area_light.hlsli"

Texture2D<float4> gbuffer0 : register(t0);
Texture2D<float4> gbuffer1 : register(t1);
Texture2D<float4> gbuffer2 : register(t2);
Texture2D<float4> gbuffer3 : register(t3);
Texture2D<float> point_shadow_front_map : register(t4);
Texture2D<float> point_shadow_back_map : register(t5);
Texture2D<float> directional_shadow_map : register(t6);

float SampleDirectionalShadow(float3 world_position, float3 normal, float3 light_dir)
{
    float4 light_view_position = mul(float4(world_position, 1.0f), light_view_projection);
    light_view_position /= light_view_position.w;

    float2 uv = light_view_position.xy * float2(0.5f, -0.5f) + 0.5f;
    bool outside_shadow_map = any(uv < 0.0f) || any(uv > 1.0f) || light_view_position.z < 0.0f || light_view_position.z > 1.0f;
    uv = saturate(uv);

    float2 shadow_map_size = float2(1.0f, 1.0f);
    directional_shadow_map.GetDimensions(shadow_map_size.x, shadow_map_size.y);
    float2 texel_size = 1.0f / shadow_map_size;

    float bias = max(0.005f * (1.0f - saturate(dot(normal, light_dir))), 0.0005f);
    float depth = saturate(light_view_position.z - bias);

    float shadow = 0.0f;
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            shadow += directional_shadow_map.SampleCmpLevelZero(
                comparison_sampler_state,
                uv + float2(x, y) * texel_size,
                depth
            );
        }
    }
    float shadow_factor = shadow / 9.0f;
    float min_shadow = 0.0f; // ここを 0.0f に近づけるほど影が濃くなります
    float final_shadow = lerp(min_shadow, 1.0f, shadow_factor);

    return outside_shadow_map ? 1.0f : final_shadow;
}

float SamplePointLightShadow(float3 world_position, float3 normal, float3 light_dir, int light_index)
{
    float3 light_vector = world_position - point_shadow_position_radius.xyz;
    float distance_from_light = length(light_vector);
    bool use_shadow =
        point_shadow_options.y > 0.0f &&
        light_index == 0 &&
        distance_from_light > point_shadow_params.x &&
        distance_from_light < point_shadow_params.y;

    float lit = 1.0f;
    if (use_shadow)
    {
        float2 uv = DualParaboloidUV(light_vector);
        float slope_bias = point_shadow_params.w * (1.0f - saturate(dot(normal, light_dir)));
        float receiver_depth = PointShadowDepth(distance_from_light) - max(point_shadow_params.w, slope_bias);
        lit = light_vector.z >= 0.0f
            ? point_shadow_front_map.SampleCmpLevelZero(comparison_sampler_state, uv, receiver_depth)
            : point_shadow_back_map.SampleCmpLevelZero(comparison_sampler_state, uv, receiver_depth);
    }

   // return lerp(1.0f - point_shadow_options.x, 1.0f, lit);
    return lerp(1.0f - 1.0f, 1.0f, lit);
}

float4 main(VS_OUT pin) : SV_TARGET
{
    float4 sampled = gbuffer0.SampleLevel(sampler_states[POINT_CLAMP], pin.texcoord, 0);
    float3 normal = normalize(sampled.xyz);
    //float3 normal = sampled.xyz;
    float roughness = sampled.w;

    sampled = gbuffer1.SampleLevel(sampler_states[POINT_CLAMP], pin.texcoord, 0);
    float3 basecolor = sampled.xyz;
    float metallic = sampled.w;

    sampled = gbuffer2.SampleLevel(sampler_states[POINT_CLAMP], pin.texcoord, 0);
    float3 position = sampled.xyz;
    float occlusion = sampled.w;

    sampled = gbuffer3.SampleLevel(sampler_states[POINT_CLAMP], pin.texcoord, 0);
    float3 emissive = sampled.xyz;

    const float3 f0 = lerp(0.04f, basecolor, metallic);
    const float3 f90 = 1.0f;
    const float alpha_roughness = roughness * roughness;
    const float3 c_diff = lerp(basecolor, 0.0f, metallic);

    const float3 N = normal;
    const float3 V = normalize(camera_position.xyz - position);
    const float NoV = max(0.0f, dot(N, V));

    //float3 diffuse = ambient_color.rgb * c_diff;
    float3 diffuse = 0;
    float3 specular = 0.0f;

    float3 L = normalize(-directional_light_direction.xyz);
    float3 Li = directional_light_color.rgb * 5;
    float NoL = max(0.0f, dot(N, L));
    if (NoL > 0.0f)
    {
        float3 H = normalize(V + L);
        float NoH = max(0.0f, dot(N, H));
        float HoV = max(0.0f, dot(H, V));
        float directional_shadow = SampleDirectionalShadow(position, N, L);
        

        diffuse += Li * directional_shadow * NoL * brdf_lambertian(f0, f90, c_diff, HoV);
        specular += Li * directional_shadow * NoL * brdf_specular_ggx(f0, f90, alpha_roughness, HoV, NoL, NoV, NoH);
    }

    for (int i = 0; i < numPointLights; ++i)
    {
        if (pointLights[i].intensity <= 0.0f || pointLights[i].radius <= 0.0f)
        {
            continue;
        }

        float3 light_vector = pointLights[i].position - position;
        float dist = length(light_vector);
        if (dist >= pointLights[i].radius)
        {
            continue;
        }

        float3 Lp = light_vector / max(dist, 0.0001f);
        float pointNoL = max(0.0f, dot(N, Lp));
        if (pointNoL <= 0.0f)
        {
            continue;
        }

        float attenuation = pow(max(0.0f, 1.0f - (dist / pointLights[i].radius)), 2.0f);
        float3 pointLi = pointLights[i].color * pointLights[i].intensity * attenuation;
        float3 H = normalize(V + Lp);
        float NoH = max(0.0f, dot(N, H));
        float HoV = max(0.0f, dot(H, V));
        float point_shadow = SamplePointLightShadow(position, N, Lp, i);

        diffuse += pointLi * point_shadow * pointNoL * brdf_lambertian(f0, f90, c_diff, HoV);
        specular += pointLi * point_shadow * pointNoL * brdf_specular_ggx(f0, f90, alpha_roughness, HoV, pointNoL, NoV, NoH);
    }

    // スポットライト
    for (int i = 0; i < numSpotLights; ++i)
    {
        if (spotLights[i].intensity <= 0.0f || spotLights[i].radius <= 0.0f)
        {
            continue;
        }

        float3 light_vector = spotLights[i].position - position;
        float dist = length(light_vector);
        if (dist >= spotLights[i].radius)
        {
            continue;
        }

        float3 Ls = light_vector / max(dist, 0.0001f);
        float spotNoL = max(0.0f, dot(N, Ls));
        if (spotNoL <= 0.0f)
        {
            continue;
        }

        // 角度減衰の計算
        float3 lightDir = normalize(spotLights[i].direction);
        float cosAngle = dot(-Ls, lightDir);
        float cosInner = cos(spotLights[i].innerAngle);
        float cosOuter = cos(spotLights[i].outerAngle);
        
        float spotAttenuation = 1.0f;
        if (cosAngle < cosOuter)
        {
            spotAttenuation = 0.0f;
        }
        else if (cosAngle < cosInner)
        {
            spotAttenuation = smoothstep(cosOuter, cosInner, cosAngle);
        }

        float distanceAttenuation = pow(max(0.0f, 1.0f - (dist / spotLights[i].radius)), 2.0f);
        float totalAttenuation = spotAttenuation * distanceAttenuation;
        
        if (totalAttenuation <= 0.0f)
        {
            continue;
        }

        float3 spotLi = spotLights[i].color * spotLights[i].intensity * totalAttenuation;
        float3 H = normalize(V + Ls);
        float NoH = max(0.0f, dot(N, H));
        float HoV = max(0.0f, dot(H, V));

        diffuse += spotLi * spotNoL * brdf_lambertian(f0, f90, c_diff, HoV);
        specular += spotLi * spotNoL * brdf_specular_ggx(f0, f90, alpha_roughness, HoV, spotNoL, NoV, NoH);
    }

   // エリアライト (LTC - Linearly Transformed Cosines)
    for (int i = 0; i < numAreaLights; ++i)
    {
        if (areaLights[i].intensity <= 0.0f)
            continue;

        // LTCによる拡散反射（BRDF考慮）
        float3 ltcDiffuse = LTC_Diffuse(N, V, position, areaLights[i], c_diff, f0, f90);
        
        // LTCによる鏡面反射（BRDF考慮）
        float3 ltcSpecular = LTC_Specular(N, V, position, areaLights[i], roughness, f0, f90);
        
        // 法線とライト方向の内積でクリッピング
        float3 lightDir = normalize(areaLights[i].direction);
        float NoL = saturate(dot(N, lightDir));
        
        diffuse += ltcDiffuse * NoL;
        specular += ltcSpecular * NoL;
    }

    diffuse += ibl_radiance_lambertian(N, V, roughness, c_diff, f0) * 0.2;
    specular += ibl_radiance_ggx(N, V, roughness, f0) * 0.2;

    diffuse *= occlusion;
    specular *= occlusion;

    float3 Lo = diffuse + specular + emissive;
    return float4(Lo, 1.0f);
}
//todo順応
