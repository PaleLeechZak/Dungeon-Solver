// HUD vertex shader: positions arrive in pixels with the origin at the top
// left of the window and are mapped straight to clip space.

cbuffer Screen : register(b0, space1)
{
    float2 screen_size;
    float2 unused;
};

struct Input
{
    float2 position : TEXCOORD0;
    float2 uv       : TEXCOORD1;
    float4 color    : TEXCOORD2;
};

struct Output
{
    float4 clip  : SV_Position;
    float2 uv    : TEXCOORD0;
    float4 color : TEXCOORD1;
};

Output main(Input input)
{
    float2 ndc = input.position / screen_size * 2.0 - 1.0;

    Output output;
    output.clip = float4(ndc.x, -ndc.y, 0.0, 1.0);
    output.uv = input.uv;
    output.color = input.color;
    return output;
}
