// Instanced tile vertex shader. SDL's GPU API addresses vertex inputs by
// location, which HLSL spells TEXCOORD<location>. Locations 0-2 come from the
// shared mesh buffer, 3-7 from the per-instance buffer.

cbuffer Frame : register(b0, space1)
{
    float4x4 view_proj;
};

struct Input
{
    float3 position : TEXCOORD0;
    float3 normal   : TEXCOORD1;
    float2 uv       : TEXCOORD2;
    // Columns of the model matrix.
    float4 model0   : TEXCOORD3;
    float4 model1   : TEXCOORD4;
    float4 model2   : TEXCOORD5;
    float4 model3   : TEXCOORD6;
    float4 tint     : TEXCOORD7;
};

struct Output
{
    float4 clip   : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv     : TEXCOORD1;
    float4 tint   : TEXCOORD2;
};

Output main(Input input)
{
    float4 world = input.model0 * input.position.x
                 + input.model1 * input.position.y
                 + input.model2 * input.position.z
                 + input.model3;

    Output output;
    output.clip = mul(view_proj, world);
    output.normal = input.model0.xyz * input.normal.x
                  + input.model1.xyz * input.normal.y
                  + input.model2.xyz * input.normal.z;
    output.uv = input.uv;
    output.tint = input.tint;
    return output;
}
