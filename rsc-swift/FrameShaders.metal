#include <metal_stdlib>
using namespace metal;

struct FrameVertex {
    float4 position [[position]];
    float2 uv;
};

// a single triangle covering the whole viewport
vertex FrameVertex frame_vertex(uint vid [[vertex_id]]) {
    float2 corner = float2((vid << 1) & 2, vid & 2);

    FrameVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

fragment float4 frame_fragment(FrameVertex in [[stage_in]],
                               texture2d<float> frame [[texture(0)]],
                               sampler frame_sampler [[sampler(0)]]) {
    // the client leaves the top byte (alpha) as 0
    return float4(frame.sample(frame_sampler, in.uv).rgb, 1.0);
}
