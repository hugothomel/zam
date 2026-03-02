#include <metal_stdlib>
using namespace metal;

// MARK: - Render Pipeline (draw textured quad)

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct ViewportParams {
    float2 scale;
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                              constant ViewportParams &params [[buffer(0)]]) {
    constexpr float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2(-1,  1), float2( 1, -1), float2( 1,  1),
    };
    constexpr float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0),
    };

    VertexOut out;
    out.position = float4(positions[vertexID] * params.scale, 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    return tex.sample(s, in.texCoord);
}

// MARK: - Compute Pipeline (CHW float → RGBA texture on GPU)

struct FrameParams {
    int width;
    int height;
    int channels;
};

kernel void chwToRGBA(
    device const float* src [[buffer(0)]],
    constant FrameParams &params [[buffer(1)]],
    texture2d<half, access::write> dst [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) return;

    int planeSize = params.width * params.height;
    int idx = int(gid.y) * params.width + int(gid.x);

    float r = src[idx];
    float g = params.channels > 1 ? src[planeSize + idx] : r;
    float b = params.channels > 2 ? src[2 * planeSize + idx] : r;

    // [-1, 1] → [0, 1]
    half4 color = half4(
        half(saturate((r + 1.0) * 0.5)),
        half(saturate((g + 1.0) * 0.5)),
        half(saturate((b + 1.0) * 0.5)),
        1.0h
    );
    dst.write(color, gid);
}
