#include <metal_stdlib>
using namespace metal;
struct Input {
    float2 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
    float4 color [[attribute(2)]];
};
struct Raster {
    float4 position [[position]];
    float2 uv [[user(locn0)]];
    float4 color [[user(locn1)]];
};
vertex Raster seggs_vertex(Input input [[stage_in]]) {
    Raster output;
    output.position = float4(input.position, 0.0, 1.0);
    output.uv = input.uv;
    output.color = input.color;
    return output;
}
fragment float4 seggs_fragment(Raster input [[stage_in]],
                              texture2d<float> atlas [[texture(0)]],
                              sampler atlas_sampler [[sampler(0)]]) {
    return atlas.sample(atlas_sampler, input.uv) * input.color;
}
