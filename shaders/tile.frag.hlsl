// Tile fragment shader: atlas colour times instance tint, lit by one fixed
// sun plus a sky/ground ambient so every face of a wall stays readable.
// The tint's alpha is not opacity: it is how far the result is pushed towards
// white, which is how a character flashes when it is hit.

Texture2D<float4> atlas : register(t0, space2);
SamplerState atlas_sampler : register(s0, space2);

struct Input
{
    float4 clip   : SV_Position;
    float3 normal : TEXCOORD0;
    float2 uv     : TEXCOORD1;
    float4 tint   : TEXCOORD2;
};

static const float3 TO_SUN = normalize(float3(0.45, 0.80, 0.35));

float4 main(Input input) : SV_Target0
{
    float3 n = normalize(input.normal);
    float sun = saturate(dot(n, TO_SUN));
    float sky = 0.5 + 0.5 * n.y;
    float light = 0.38 + 0.47 * sun + 0.15 * sky;

    float4 base = atlas.Sample(atlas_sampler, input.uv);
    float3 lit = base.rgb * input.tint.rgb * light;
    return float4(lerp(lit, float3(1.0, 1.0, 1.0), saturate(input.tint.a)), 1.0);
}
