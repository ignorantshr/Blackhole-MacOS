#include <metal_stdlib>
using namespace metal;

constant float pi = 3.14159265359;

struct RenderUniforms {
    float2 resolution;
    float time;
    float radius;
    float2 screenResolution;
};

struct VertexOutput {
    float4 position [[position]];
};

vertex VertexOutput blackHoleVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOutput output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    return output;
}

float2 rotate2D(float2 value, float angle) {
    float cosine = cos(angle);
    float sine = sin(angle);
    return float2(cosine * value.x - sine * value.y, sine * value.x + cosine * value.y);
}

float hash21(float2 value) {
    value = fract(value * float2(123.34, 456.21));
    value += dot(value, value + 45.32);
    return fract(value.x * value.y);
}

float valueNoise(float2 value) {
    float2 cell = floor(value);
    float2 fraction = fract(value);
    fraction = fraction * fraction * (3.0 - 2.0 * fraction);
    float lower = mix(hash21(cell), hash21(cell + float2(1.0, 0.0)), fraction.x);
    float upper = mix(hash21(cell + float2(0.0, 1.0)), hash21(cell + 1.0), fraction.x);
    return mix(lower, upper, fraction.y);
}

float fractalNoise(float2 value) {
    float noise = 0.0;
    float amplitude = 0.5;
    for (int octave = 0; octave < 4; octave++) {
        noise += amplitude * valueNoise(value);
        value = rotate2D(value * 2.03 + 17.1, 0.47);
        amplitude *= 0.5;
    }
    return noise;
}

float maximumComponent(float3 value) {
    return max(value.x, max(value.y, value.z));
}

fragment float4 blackHoleFragment(
    VertexOutput input [[stage_in]],
    constant RenderUniforms &uniforms [[buffer(0)]],
    texture2d<float> screenTexture [[texture(0)]]
) {
    constexpr sampler screenSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = input.position.xy / uniforms.resolution;
    bool hasScreen = all(uniforms.screenResolution > 0.0);
    float4 desktop = hasScreen ? screenTexture.sample(screenSampler, uv) : float4(0.0);
    float aspect = uniforms.resolution.x / uniforms.resolution.y;
    float time = uniforms.time;

    float2 center = float2(
        0.50 + 0.205 * sin(time * 0.071 + 0.8) + 0.045 * sin(time * 0.157),
        0.43 + 0.165 * sin(time * 0.059 + 2.1) + 0.035 * sin(time * 0.131)
    );
    float scale = uniforms.radius * (1.0 + 0.025 * sin(time * 0.39));
    float2 point = float2((uv.x - center.x) * aspect, uv.y - center.y) / scale;
    point = rotate2D(point, -0.19);

    float ellipticalRadius = length(point * float2(0.91, 1.12));
    float influence = 1.0 - smoothstep(1.7, 8.8, ellipticalRadius);
    if (influence <= 0.0001) {
        return desktop;
    }

    float angle = atan2(point.y, point.x);
    float inverseRadius = 1.0 / max(ellipticalRadius, 0.13);
    float streamNoise = fractalNoise(float2(
        angle * 1.8 + time * 0.07,
        log(ellipticalRadius + 0.12) * 3.7 - time * 0.13
    ));
    float asymmetry = 0.72 + 0.28 * sin(angle * 2.0 - time * 0.11 + streamNoise * 2.8);

    float2 radialDirection = point * inverseRadius;
    float2 tangentDirection = float2(-radialDirection.y, radialDirection.x);
    float pull = influence * influence * (0.14 + 0.78 * inverseRadius);
    float curl = influence * (0.30 + 1.15 * inverseRadius) * asymmetry;
    float turbulence = (streamNoise - 0.5) * influence * 0.16;
    float2 warpedPoint = point
        + radialDirection * pull
        + tangentDirection * (curl + turbulence);

    float2 rotatedWarp = rotate2D(warpedPoint * scale, 0.19);
    float2 warpedUV = center + float2(rotatedWarp.x / aspect, rotatedWarp.y);
    float3 warpedDesktop = hasScreen
        ? screenTexture.sample(screenSampler, warpedUV).rgb
        : float3(0.0);

    float coreShape = length(point * float2(0.84, 1.16));
    float coreMask = 1.0 - smoothstep(0.62, 1.34, coreShape);
    float throat = 1.0 - smoothstep(0.16, 0.82, coreShape);
    float darkCurrent = influence * (0.20 + 0.42 * inverseRadius);
    darkCurrent *= 0.72 + 0.28 * fractalNoise(point * 1.7 - float2(time * 0.04, time * 0.07));
    float attenuation = clamp(darkCurrent + coreMask * 0.88 + throat, 0.0, 1.0);

    float3 dustLight = float3(0.0);
    float dustMask = 0.0;
    for (int layer = 0; layer < 4; layer++) {
        float layerValue = float(layer);
        float spiralAngle = angle + log(ellipticalRadius + 0.18) * (2.0 + layerValue * 0.19);
        float lane = fract(
            spiralAngle / (2.0 * pi) * (12.0 + layerValue * 5.0)
            - time * (0.20 + layerValue * 0.035)
            + hash21(float2(floor(ellipticalRadius * (5.0 + layerValue)), layerValue))
        );
        float speck = pow(max(0.0, 1.0 - abs(lane - 0.5) * 15.0), 7.0);
        float radialGate = smoothstep(0.48, 1.25, ellipticalRadius)
            * (1.0 - smoothstep(3.0 + layerValue * 0.42, 6.8, ellipticalRadius));
        float breakup = smoothstep(
            0.52,
            0.88,
            fractalNoise(point * (4.8 + layerValue * 1.7) + layerValue * 13.0)
        );
        float particle = speck * radialGate * mix(0.28, 1.0, breakup);
        float heat = 1.0 - smoothstep(0.65, 4.8, ellipticalRadius);
        float3 particleColor = mix(
            float3(0.24, 0.055, 0.018),
            float3(1.0, 0.50, 0.10),
            heat
        );
        particleColor = mix(particleColor, float3(1.0, 0.87, 0.52), heat * heat * 0.78);
        dustLight += particleColor * particle * (0.45 + heat * 2.5);
        dustMask = max(dustMask, particle);
    }

    float shearBand = exp(-pow((coreShape - 1.28) / 0.34, 2.0));
    shearBand *= 0.18 + 0.38 * fractalNoise(float2(angle * 5.0 - time * 0.18, coreShape * 9.0));
    float3 ember = float3(0.55, 0.10, 0.018) * shearBand * influence;

    float3 composed = warpedDesktop * (1.0 - attenuation);
    composed += dustLight + ember;
    composed *= 1.0 - throat;

    if (hasScreen) {
        float blend = clamp(influence * 0.94 + coreMask + dustMask, 0.0, 1.0);
        return float4(mix(desktop.rgb, composed, blend), 1.0);
    }

    float alpha = clamp(max(attenuation * influence, maximumComponent(dustLight + ember)), 0.0, 1.0);
    return float4(clamp(dustLight + ember, 0.0, 1.0), alpha);
}
