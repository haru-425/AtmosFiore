cbuffer POINT_SHADOW_CONSTANT_BUFFER : register(b5)
{
    float4 point_shadow_position_radius; // xyz: light position, w: radius
    float4 point_shadow_params;          // x: near, y: far, z: z sign, w: depth bias
    float4 point_shadow_options;         // x: strength, y: enabled
};

float2 DualParaboloidUV(float3 light_vector)
{
    float3 direction = normalize(light_vector);
    float z = abs(direction.z);
    return direction.xy / (z + 1.0f) * float2(0.5f, -0.5f) + 0.5f;
}

float PointShadowDepth(float distance_from_light)
{
    return saturate((distance_from_light - point_shadow_params.x) /
        max(point_shadow_params.y - point_shadow_params.x, 0.0001f));
}
