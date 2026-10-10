// HUD fragment shader. The glyph atlas is white with coverage in alpha, so
// multiplying by the vertex colour tints text, icons and flat shapes alike.

Texture2D<float4> atlas : register(t0, space2);
SamplerState atlas_sampler : register(s0, space2);

struct Input
{
    float4 clip  : SV_Position;
    float2 uv    : TEXCOORD0;
    float4 color : TEXCOORD1;
};

float4 main(Input input) : SV_Target0
{
    return atlas.Sample(atlas_sampler, input.uv) * input.color;
}
