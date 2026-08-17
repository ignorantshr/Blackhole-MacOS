#include <metal_stdlib>
using namespace metal;

// 物理黑洞覆盖层着色器
//
// 视觉模型改编自 ghostty-blackhole（https://github.com/s0xDk/ghostty-blackhole，
// MIT 协议，版权见仓库根目录 THIRD-PARTY-NOTICES.md）：核心是每个像素直接数值
// 积分 Schwarzschild 零测地线（下方两级查找表只是对该积分的等价加速，见 README）。
// Binet 形式的光子加速度  a = -(3/2) h^2 x / r^5  精确复现史瓦西偏折，
// 因此以下现象全部来自积分本身，而不是叠加绘制的贴图：
//
//   * 阴影      —— 冲击参数小于 b_crit = (3√3/2) r_s 的光线落入视界
//   * 引力透镜  —— 逃逸光线被投影回“桌面天空平面”，桌面发生弯曲与镜像
//   * 光子环    —— 在 r = 1.5 r_s 光子球附近绕行的光线
//   * 吸积盘    —— 薄开普勒盘，光线可多次穿越（远侧在阴影上下形成弧）；
//                  Shakura–Sunyaev 温度剖面给出黑体色，并按相对论因子
//                  g = √(1 − 1.5 r_s/r) / (1 − β·k̂) 做多普勒偏色与集束增亮
//   * 星场      —— 微弱的被透镜化天空，保证桌面为纯黑时弯曲依然可读
//
// 单位约定：史瓦西半径 r_s = 1。屏幕映射把阴影半径与 uniforms.radius 绑定。

// ------------------------------------------------------------------ 可调参数 --
// 黑洞与透镜
constant float kLensDepth   = 13.0;   // 黑洞到桌面“天空平面”的距离（r_s），越大桌面弯曲越强
constant float kStarGain    = 0.35;   // 被透镜化星场亮度（0 = 关闭）
// 吸积盘几何（半径单位为 r_s）
constant float kDiskInner   = 1.8;    // 内边缘，3 r_s 为 ISCO 最内稳定圆轨道
constant float kDiskOuter   = 8.0;    // 外边缘
constant float kDiskIncl    = 1.5;    // 倾角（弧度）：0 为正对，1.57 为侧视
constant float kDiskRoll    = 0.35;   // 整个系统在屏幕平面内的滚转（弧度）
// 吸积盘物质与光照
constant float kDiskGain    = 2.2;    // 盘发光强度
constant float kDiskOpacity = 0.9;    // 近侧盘对背后景象的遮挡程度（0..1）
constant float kDiskTemp    = 5500.0; // 最热环带温度（K），决定黑体颜色
constant float kDopplerMix  = 0.6;    // 0 = 无相对论色/亮度不对称，1 = 完整效果
constant float kDiskBeam    = 2.5;    // 集束指数：观测强度按 g^N 变化
constant float kDiskSpeed   = 5.0;    // 条纹图案速度，负值反转旋转方向
constant float kDiskWind    = 7.0;    // 条纹螺旋缠绕紧密度
constant float kDiskContrast = 1.6;   // 条纹对比度：0 为平滑雾状，越大越锐利
// 光照与屏幕
constant float kExposure    = 1.4;    // 盘光的色调映射曝光（桌面像素本身不受影响）
constant float kDriftSpeed  = 0.5;    // 黑洞漂移基础速度（统一缩放整个 --speed 范围）
// 有界重采样场（单位为测地线近场半径的倍数，默认近场半径约 4.2 个阴影半径）。
// 三者必须满足 kLensReach < kFieldWarp < kFieldOuter：位移要先严格归零，
// 覆盖才能归零，否则边界会把畸变后的桌面与实时桌面交叉淡化而产生重影。
//
// 这是一组保真度与开销的权衡，不是免费优化：真实弱透镜位移按 1/b 衰减，
// 要衰减到亚像素需要约 11 个阴影半径，那样场几乎铺满整屏、省不下开销。
// 当前默认值在约 7.4 个阴影半径处截断，中场位移最大与无界解相差约 17px
// （出现在约 3.4 个阴影半径处的弱畸变区），换来 16:10 下约 55%、
// 21:9 下约 69% 的像素完全跳过重采样。调大三者可提升保真度并提高开销。
constant float kLensReach   = 1.05;   // 位移的高斯衰减尺度，越大桌面被拖动的范围越广
constant float kFieldWarp   = 1.75;   // 位移严格归零处
constant float kFieldOuter  = 2.05;   // 覆盖归零处，向外即完全透明

// 每像素测地线积分步数，只有黑洞附近的像素才付出这份开销。
#define N_STEPS 48

// 史瓦西黑洞的临界冲击参数（单位 r_s）：小于此值的光线落入视界，
// 它同时也是远处观测到的阴影视半径。属于物理常量，不是风格参数。
#define B_CRIT 2.5980762

// 预计算逃逸测地线查找表的维度，必须与 BlackHoleOverlay.swift 的
// GeodesicLUT.lensSamples / gateAzimuths 完全一致（改一处要同步另一处）。
//   kLensSamples —— 透镜表条目数，b 在 [B_CRIT, maxImpact] 上等距采样
//   kGateAzimuths —— 盘门控表方位桶数
#define kLensSamples 1024
#define kGateAzimuths 180

// 吸积盘二维查表维度（方案A第二步），必须与 BlackHoleOverlay.swift 的
// GeodesicLUT.diskBSamples / diskThetaSamples 一致。表按 (b, θ) 索引，
// θ 为光线在自身 2D 轨道平面内的累积极角。
#define kDiskBSamples 256
#define kDiskThetaSamples 256
// 混合门限：b < kGateBFactor·B_CRIT 的光子环环带仍走完整积分（含全部多次穿越），
// b ≥ 该门限的单次穿盘像素才用盘表重建。必须与 Swift 的 gateBFactor 一致。
#define kGateBFactor 1.5
// 盘表 θ 采样上限，覆盖近侧+远侧穿越。必须与 Swift 的 diskThetaMax 一致。
#define kDiskThetaMax (1.5 * 3.14159265359)
// 盘表 θ 采样下界：入射极角 atan2(B_CRIT, cameraDistance)，cameraDistance=14。
// 必须与 Swift 的 diskTheta0 = atan2f(bCrit, cameraDistance) 一致。
#define kDiskTheta0 atan2((float)B_CRIT, 14.0)

constant float pi = 3.14159265359;

struct RenderUniforms {
    float2 resolution;
    float time;
    float radius;
    float2 screenResolution;
    float2 seed;        // 每块屏幕独立的随机相位，令漂移轨迹各不相同且不同步
    float driftPhase;   // CPU 侧逐帧累积的漂移相位（∫速度 dt），改速度不跳变
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

// -------------------------------------------------------------------- 噪声 --
float hash21(float2 value) {
    value = fract(value * float2(234.34, 435.345));
    value += dot(value, value + 34.23);
    return fract(value.x * value.y);
}

// y 方向每 period 格循环的 value noise：用于盘的角向维度，
// 让条纹跨过 atan 分支切口时无缝衔接（period 必须是整数，
// 且每转一圈 y 恰好前进 period）
float valueNoiseWrapY(float2 value, float period) {
    float2 cell = floor(value);
    float2 fraction = fract(value);
    fraction = fraction * fraction * (3.0 - 2.0 * fraction);
    float y0 = fmod(cell.y, period);
    float y1 = fmod(cell.y + 1.0, period);
    return mix(
        mix(hash21(float2(cell.x, y0)), hash21(float2(cell.x + 1.0, y0)), fraction.x),
        mix(hash21(float2(cell.x, y1)), hash21(float2(cell.x + 1.0, y1)), fraction.x),
        fraction.y
    );
}

// 镜像重复：让被透镜化的采样点始终落在屏幕内，且边缘不会拉丝
float2 mirrorUV(float2 value) {
    return 1.0 - abs(1.0 - fmod(fmod(value, 2.0) + 2.0, 2.0));
}

// 黑体颜色（开尔文，Tanner Helland 拟合，已归一化）
float3 blackbody(float temperature) {
    float t = clamp(temperature, 1500.0, 40000.0) / 100.0;
    float r = t <= 66.0
        ? 1.0
        : clamp(1.292936 * pow(t - 60.0, -0.1332047), 0.0, 1.0);
    float g = t <= 66.0
        ? clamp(0.3900816 * log(t) - 0.6318414, 0.0, 1.0)
        : clamp(1.1298909 * pow(t - 60.0, -0.0755148), 0.0, 1.0);
    float b = t >= 66.0
        ? 1.0
        : (t <= 19.0 ? 0.0 : clamp(0.5432068 * log(t - 10.0) - 1.1962540, 0.0, 1.0));
    return float3(r, g, b);
}

// 按光线方向索引的稀疏程序化星场。因为使用的是偏折后的光线方向，
// 星点会自然地在黑洞周围被拉成弧线。
float3 starfield(float3 direction, float time) {
    float2 spherical = float2(atan2(direction.x, -direction.z), asin(clamp(direction.y, -1.0, 1.0)));
    float2 grid = spherical * 40.0;
    float2 cell = floor(grid);
    float h = hash21(cell);
    if (h < 0.92) {
        return float3(0.0);
    }
    float2 fraction = fract(grid) - 0.5;
    float2 offset = (float2(hash21(cell + 17.3), hash21(cell + 31.7)) - 0.5) * 0.7;
    float spark = smoothstep(0.10, 0.0, length(fraction - offset));
    float twinkle = 0.7 + 0.3 * sin(time * (0.5 + 2.0 * hash21(cell + 5.1)) + 40.0 * h);
    float3 tint = mix(float3(1.0, 0.82, 0.60), float3(0.75, 0.85, 1.0), hash21(cell + 2.9));
    return tint * spark * twinkle * ((h - 0.92) / 0.08);
}

// 不规则的 Lissajous 漫游：每个轴 2+2 个不可公度正弦，轨迹不会明显重复。
// phase 为每块屏幕独立的随机相位，令各屏轨迹互不相同、互不同步。
float2 lissajous(float t, float2 phase) {
    return float2(
        0.75 * sin(t * 0.37 + phase.x) + 0.25 * sin(t * 0.83 + 1.0 + phase.y),
        0.70 * sin(t * 0.54 + 2.1 + phase.y) + 0.30 * sin(t * 1.07 + phase.x)
    );
}

// ------------------------------------------------------ 预计算查找表 --
// 逃逸测地线的终点状态是冲击参数 b 的一元函数（史瓦西中心力场 → 平面运动）。
// 主机端已在 [B_CRIT, maxImpact] 上把它制成一维表：每格 (px, pz, dx, dz)，
// 其中 (px, pz) 是光线在自身 2D 轨道平面内的终点位置（px 为横向、初始沿 +b 方向），
// (dx, dz) 是归一化终点方向。这里线性插值取回该状态。
struct LensSample { float px; float pz; float dx; float dz; };

LensSample sampleLensTable(constant float4 *lensTable, float impactParameter) {
    float f = (impactParameter - B_CRIT) / (11.0 - B_CRIT) * float(kLensSamples - 1);
    f = clamp(f, 0.0, float(kLensSamples - 1));
    int i0 = int(floor(f));
    int i1 = min(i0 + 1, kLensSamples - 1);
    float frac = f - float(i0);
    float4 a = lensTable[i0];
    float4 b = lensTable[i1];
    float4 s = mix(a, b, frac);
    LensSample out;
    out.px = s.x; out.pz = s.y; out.dx = s.z; out.dz = s.w;
    return out;
}

// 盘门控：给定像素在盘系（已施加滚转）里的方位角与冲击参数，判断这条光线是否
// “保证碰不到吸积盘”。碰不到 → 可跳过 48 步积分直接查透镜表；否则仍需完整积分。
// gateTable[方位桶] = (loB, hiB)：只有 b∈[loB,hiB] 才可能穿盘（主机端已保守外扩）。
bool rayMissesDisk(constant float2 *gateTable, float azimuth, float impactParameter) {
    float a = azimuth;
    if (a < 0.0) { a += 2.0 * pi; }
    int bucket = int(a / (2.0 * pi) * float(kGateAzimuths));
    bucket = clamp(bucket, 0, kGateAzimuths - 1);
    float2 span = gateTable[bucket];
    return impactParameter < span.x || impactParameter > span.y;
}

// 单个盘穿越点的着色：给定穿越点、该处光线速度、盘正交系与转动参数，
// 返回本次穿越对累积发光的贡献增量（已乘 transmittance）与不透明度。
// 积分路径与查表路径共用同一段物理，保证两条路径盘光一致。
struct DiskShade { float3 emissionAdd; float opacity; };

DiskShade shadeDiskCrossing(
    float3 crossPoint, float3 velocity, float3 diskNormal, float3 diskAxis,
    float spinDirection, float spinSpeed, float diskInner, float diskOuter,
    float time, float transmittance
) {
    DiskShade result;
    result.emissionAdd = float3(0.0);
    result.opacity = 0.0;
    float crossRadius = length(crossPoint);
    if (!(crossRadius > diskInner && crossRadius < diskOuter)) {
        return result;
    }
    float band = smoothstep(diskInner, diskInner * 1.25, crossRadius)
        * (1.0 - smoothstep(diskOuter * 0.70, diskOuter, crossRadius));

    // 盘平面极坐标，用于条纹纹理
    float phi = atan2(dot(crossPoint, diskAxis), crossPoint.x);
    float turns = phi / (2.0 * pi);
    float keplerRate = pow(diskInner / crossRadius, 1.5);
    // √(1 − 1.5/r)：内侧轨道时间流逝更慢，图案在内边缘明显凝滞
    float gravitationalFactor = sqrt(max(1.0 - 1.5 / crossRadius, 0.02));
    float swirl = crossRadius * kDiskWind * 0.12
        - time * keplerRate * spinSpeed * gravitationalFactor * spinDirection;
    float streaks =
        valueNoiseWrapY(float2(crossRadius * 2.8, turns * 19.0 + swirl * 3.0), 19.0) * 0.65 +
        valueNoiseWrapY(float2(crossRadius * 1.0, turns * 9.0 + swirl * 1.5 + 7.0), 9.0) * 0.35;
    streaks = 0.35 + kDiskContrast * streaks * streaks;

    // 圆轨道气体的相对论多普勒 + 引力红移：
    // g = √(1 − 1.5/r) / (1 − β·k̂)，光子方向直接取自当前光线
    float3 gasDirection = normalize(cross(diskNormal, crossPoint)) * spinDirection;
    float beta = clamp(rsqrt(max(2.0 * (crossRadius - 1.0), 0.2)), 0.0, 0.99);
    float shift = gravitationalFactor
        / max(1.0 + beta * dot(gasDirection, normalize(velocity)), 0.05);
    shift = mix(1.0, shift, kDopplerMix);

    // Shakura–Sunyaev 温度剖面，峰值归一化到 1
    float temperatureEdge = max(1.0 - sqrt(diskInner / crossRadius), 0.0);
    float temperatureProfile = pow(diskInner / crossRadius, 0.75)
        * pow(temperatureEdge, 0.25) / 0.488;
    float3 diskColor = blackbody(kDiskTemp * temperatureProfile * shift); // 多普勒偏色
    float boost = pow(shift, kDiskBeam);                                  // 相对论集束

    float density = band * streaks;
    result.emissionAdd = transmittance * diskColor
        * (kDiskGain * 2.2 * density * temperatureProfile * temperatureProfile * boost);
    result.opacity = clamp(kDiskOpacity * density, 0.0, 1.0);
    return result;
}

// 吸积盘二维表查询：在 (b, θ) 上双线性插值取回 (r, vs, vz)。
// θ 超出该 b 实际轨迹范围时表存 0，任一角点为 0 视为无效穿越，返回 false。
struct DiskSample { float radius; float vs; float vz; };

bool sampleDiskTable(constant float4 *diskTable, float impactParameter, float theta,
                     thread DiskSample &out) {
    float fb = (impactParameter - B_CRIT) / (11.0 - B_CRIT) * float(kDiskBSamples - 1);
    fb = clamp(fb, 0.0, float(kDiskBSamples - 1));
    float ft = (theta - kDiskTheta0) / (kDiskThetaMax - kDiskTheta0) * float(kDiskThetaSamples - 1);
    if (ft < 0.0 || ft > float(kDiskThetaSamples - 1)) { return false; }
    int b0 = int(floor(fb)), t0 = int(floor(ft));
    int b1 = min(b0 + 1, kDiskBSamples - 1), t1 = min(t0 + 1, kDiskThetaSamples - 1);
    float bf = fb - float(b0), tf = ft - float(t0);
    float4 v00 = diskTable[b0 * kDiskThetaSamples + t0];
    float4 v01 = diskTable[b0 * kDiskThetaSamples + t1];
    float4 v10 = diskTable[b1 * kDiskThetaSamples + t0];
    float4 v11 = diskTable[b1 * kDiskThetaSamples + t1];
    // 任一角点半径为 0 → θ 超出该 b 的轨迹范围，插值会被污染，判为无效
    if (v00.x == 0.0 || v01.x == 0.0 || v10.x == 0.0 || v11.x == 0.0) { return false; }
    float4 s = mix(mix(v00, v01, tf), mix(v10, v11, tf), bf);
    out.radius = s.x; out.vs = s.y; out.vz = s.z;
    return true;
}

fragment float4 blackHoleFragment(
    VertexOutput input [[stage_in]],
    constant RenderUniforms &uniforms [[buffer(0)]],
    constant float4 *lensTable [[buffer(1)]],   // 逃逸测地线终点：(px, pz, dx, dz)，b 等距采样
    constant float2 *gateTable [[buffer(2)]],   // 盘门控：每方位 (loB, hiB) 冲击参数区间
    constant float4 *diskTable [[buffer(3)]],   // 吸积盘二维表：(b, θ) → (r, vs, vz, 0)
    texture2d<float> screenTexture [[texture(0)]]
) {
    constexpr sampler screenSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = input.position.xy / uniforms.resolution;
    float aspect = uniforms.resolution.x / uniforms.resolution.y;
    bool hasScreen = all(uniforms.screenResolution > 0.0);
    // time 为原始时间，驱动吸积盘旋转等物理动画，不受漂移速度影响
    float time = uniforms.time;
    // 漫游用的时间轴：CPU 已把“用户速度倍率×dt”逐帧累积进 driftPhase，
    // 这里只再乘基础漂移速度。改速度只影响此后推进快慢，不会重解释历史、不跳变。
    float driftClock = uniforms.driftPhase * kDriftSpeed;

    // 盘的径向范围做一次保护：内边缘保持在光子球（1.5 r_s）之外，
    // 在光子球以内圆轨道已不再有物理意义
    float diskInner = max(kDiskInner, 1.6);
    float diskOuter = max(kDiskOuter, diskInner + 0.5);

    // 黑洞在屏幕上缓慢漫游，并留出边距让阴影和内侧亮盘不出画
    float shadowRadius = uniforms.radius;
    float diskExtent = (diskOuter / B_CRIT) * shadowRadius;
    float marginY = min(diskExtent * 1.05, 0.42);
    float marginX = marginY / aspect;
    float2 low = float2(min(marginX, 0.5), min(marginY, 0.5));
    float2 high = float2(max(0.5, 1.0 - marginX), max(0.5, 1.0 - marginY));
    float2 room = max((high - low) * 0.5, float2(0.0));
    float2 wobbleAmplitude = min(float2(0.02), max(room * 0.3, float2(0.004)));
    float2 driftAmplitude = max(room - wobbleAmplitude, float2(0.0));
    // seed.x 作为随机相位，seed.y 作为随机时间偏移：每次启动、每块屏幕
    // 都从轨迹的不同位置出发，各屏互不同步。
    float2 phase = float2(uniforms.seed.x, uniforms.seed.x + 1.7);
    float driftTime = driftClock + uniforms.seed.y;
    float2 center = (low + high) * 0.5
        + lissajous(driftTime * 0.35, phase) * driftAmplitude
        + wobbleAmplitude * float2(cos(driftTime * 0.8 + uniforms.seed.x),
                                   sin(driftTime * 1.0 + uniforms.seed.x));

    // 以黑洞为中心、按宽高比校正的坐标系（y 以屏幕高度为单位）
    float2 p = (uv - center) * float2(aspect, 1.0);
    float pixelRadius = length(p);

    // 屏幕与世界的映射：阴影真实视半径为 B_CRIT r_s，需要它在屏幕上占
    // shadowRadius，因此 1 个屏幕单位等于 worldScale 个史瓦西半径。
    // rayPoint 是该像素在世界单位下的位置（y 朝上，并施加系统滚转）。
    float worldScale = B_CRIT / max(shadowRadius, 1e-4);
    float2 rayPoint = rotate2D(float2(p.x, -p.y), kDiskRoll) * worldScale;
    float impactParameter = length(rayPoint);

    float maxImpact = diskOuter + 3.0;              // 超过此值的光线碰不到盘
    float cameraDistance = max(14.0, diskOuter + 5.0); // 相机距离，与积分器共用

    // ==================== 有界重采样场 ====================
    // 覆盖层只在黑洞附近重采样桌面，场之外的像素保持完全透明，
    // 由 macOS 直接合成真实桌面：既省掉整屏取样，也避免整屏桌面副本
    // 带来的延迟、拖影和受保护内容异常。
    //
    // 三个半径以测地线近场半径为基准，全部随黑洞尺寸缩放：
    //   lensReach —— 位移的高斯衰减尺度
    //   warpOuter —— 位移严格归零处
    //   fieldOuter —— 覆盖归零处，向外即完全透明
    //
    // 关键约束：位移必须在覆盖遮罩之前收敛到 0。两者之间的环带里，
    // 重采样结果已经等于未畸变桌面，因此淡出覆盖不会产生重影或接缝；
    // 若顺序颠倒，边界处会把一张被畸变的桌面与真实桌面交叉淡化。
    float nearFieldRadius = maxImpact * shadowRadius / B_CRIT;
    float lensReach = nearFieldRadius * kLensReach;
    float warpOuter = nearFieldRadius * kFieldWarp;
    float fieldOuter = nearFieldRadius * kFieldOuter;

    // 真实透镜按 1/b 衰减，会让整屏桌面随黑洞漂移而抖动；高斯项负责主体
    // 衰减，taper 项把尾部压到严格为 0（与远场屏蔽一样，是刻意的非物理处理）
    float window = exp(-pow(pixelRadius / max(lensReach, 1e-5), 2.0))
        * (1.0 - smoothstep(warpOuter * 0.72, warpOuter, pixelRadius));

    // 覆盖遮罩：向外淡出到完全透明，让下方桌面原样透出
    float coverage = 1.0 - smoothstep(warpOuter, fieldOuter, pixelRadius);
    if (coverage <= 0.0) {
        return float4(0.0);
    }

    // ======================== 远场：解析弱偏折 ==========================
    // 测地线区域的光线从有限相机距离 z = cameraDistance 出发并投影回天空平面，
    // 因此偏折小于教科书中来自无穷远的 alpha = 2 r_s/b；直接用后者会在交接
    // 半径处留下约 20% 的位移跳变，形成可见圆环接缝。
    // 下式是同一有限相机映射针对积分器的拟合（边界处误差小于 1%）。
    if (impactParameter >= maxImpact) {
        if (!hasScreen) {
            return float4(0.0);
        }
        float u = cameraDistance * rsqrt(cameraDistance * cameraDistance + impactParameter * impactParameter);
        float deflection = (2.0 / (worldScale * worldScale)) / max(pixelRadius, 1e-4)
            * (1.29 * u + 0.07)
            * max(kLensDepth - 2.14 * u + 0.75, 0.0)
            * window;
        float2 direction = p / max(pixelRadius, 1e-5);
        float3 lensed;
        // 轻微色散：蓝光比红光多弯折一点，远离交接圆后淡出（测地线一侧不做色散）
        float aberration = 0.035 * smoothstep(1.0, 2.0, impactParameter / maxImpact);
        if (aberration < 1e-4) {
            // 交接圆附近色散为 0，三通道偏折相同，采一次即可（省 2 次纹理采样）
            float2 sampleOffset = p - direction * deflection;
            float2 sampleUV = mirrorUV(center + sampleOffset / float2(aspect, 1.0));
            lensed = screenTexture.sample(screenSampler, sampleUV).rgb;
        } else {
            lensed = float3(0.0);
            for (int i = 0; i < 3; i++) {
                float k = 1.0 + (float(i) - 1.0) * aberration;
                float2 sampleOffset = p - direction * deflection * k;
                float2 sampleUV = mirrorUV(center + sampleOffset / float2(aspect, 1.0));
                lensed[i] = screenTexture.sample(screenSampler, sampleUV)[i];
            }
        }
        // 与测地线区域共用同一星场，经弱场偏折照亮，避免星点在边界圆突然出现
        float3 skyDirection = normalize(float3(-(rayPoint / impactParameter) * (2.0 / impactParameter), -1.0));
        float3 farField = lensed + starfield(skyDirection, uniforms.time) * kStarGain * window;
        // 混合状态是预乘 alpha，因此 RGB 与 alpha 同乘 coverage：
        // coverage 到 0 的过程中，这里的采样已收敛为未畸变桌面，淡出无接缝
        return float4(farField * coverage, coverage);
    }

    // ========================= 近场：积分测地线（或查表快路径）=========================
    // 来自远处相机（+z 方向）的平行光线。黑洞位于原点，r_s = 1。
    // 积分 x'' = -(3/2) h^2 x / r^5（精确的史瓦西光子偏折）；
    // h = |x×v| 是守恒量，只需计算一次。
    float3 position = float3(rayPoint, cameraDistance);
    float3 velocity = float3(0.0, 0.0, -1.0);
    float3 emission = float3(0.0);   // 累积的盘光（HDR）
    float transmittance = 1.0;       // 朝向背景的透过率
    bool captured = false;

    // 查表快路径判据。两条查表路径都要求 b ≥ B_CRIT（阴影核心之外，恒逃逸不被捕获），
    // 逃逸终点是 b 的一元函数，可直接查透镜表重建，省掉整段 48 步积分：
    //   useLensTable —— 盘门控保证这条光线碰不到吸积盘，只查透镜表、盘光恒为 0；
    //   useDiskTable —— 光线可能穿盘，但 b ≥ kGateBFactor·B_CRIT（光子环环带以外，
    //                    验证表明该区恒为单次穿越），透镜表重建几何后再用盘二维表
    //                    重建近侧/远侧穿越点并着色。
    // 阴影核心（b < B_CRIT）与光子环环带（b < kGateBFactor·B_CRIT，含全部多次穿越）
    // 仍走下方完整积分，保证光子环物理与多次穿越准确。
    float rayAzimuth = atan2(rayPoint.y, rayPoint.x);
    bool aboveCore = impactParameter >= B_CRIT;
    bool missesDisk = rayMissesDisk(gateTable, rayAzimuth, impactParameter);
    bool useLensTable = aboveCore && missesDisk;
    bool useDiskTable = aboveCore && !missesDisk
        && impactParameter >= kGateBFactor * B_CRIT;

    if (useLensTable || useDiskTable) {
        // 查表并把平面内终点状态沿像素方位旋转回 3D（中心力场 → 平面运动）
        LensSample ls = sampleLensTable(lensTable, impactParameter);
        float2 radial = rayPoint / max(impactParameter, 1e-5);
        position = float3(radial * ls.px, ls.pz);
        velocity = float3(radial * ls.dx, ls.dz);   // 已归一化

        if (useDiskTable) {
            // 盘二维表重建：解析求穿盘极角 θ*，用盘表在 (b, θ) 取回穿越半径与速度。
            // 盘正交系与积分路径一致。P·n=0 在光线平面内的解：
            //   tan(θ*) = -cosI / ((ry/b)·sinI)，近侧/远侧相差 π。
            float cosIncl = cos(kDiskIncl);
            float sinIncl = sin(kDiskIncl);
            float3 diskNormal = float3(0.0, sinIncl, cosIncl);
            float3 diskAxis = float3(0.0, cosIncl, -sinIncl);
            float spinDirection = kDiskSpeed < 0.0 ? -1.0 : 1.0;
            float spinSpeed = abs(kDiskSpeed);
            float denom = radial.y * sinIncl;
            float baseTheta = (abs(denom) < 1e-4) ? (0.5 * pi) : atan2(-cosIncl, denom);
            // 候选穿越 θ：baseTheta 及 +π/+2π，各自归一到 ≥ kDiskTheta0 的可查范围。
            // 归一后可能出现重合（baseTheta 与 baseTheta+π 落到同一 θ），需去重，
            // 否则同一穿越会被累加两次。按 θ 升序处理保证透过率累加次序正确。
            float thetas[3];
            int nTheta = 0;
            for (int k = 0; k < 3; k++) {
                float th = baseTheta + float(k) * pi;
                while (th < kDiskTheta0) { th += pi; }
                bool dup = false;
                for (int j = 0; j < nTheta; j++) {
                    if (abs(th - thetas[j]) < 1e-3) { dup = true; break; }
                }
                if (!dup) { thetas[nTheta++] = th; }
            }
            // 升序排序（最多 3 个，插入排序）
            for (int a = 1; a < nTheta; a++) {
                float key = thetas[a];
                int b = a - 1;
                while (b >= 0 && thetas[b] > key) { thetas[b + 1] = thetas[b]; b--; }
                thetas[b + 1] = key;
            }
            for (int t = 0; t < nTheta; t++) {
                if (transmittance <= 0.02) { break; }
                float th = thetas[t];
                DiskSample ds;
                if (!sampleDiskTable(diskTable, impactParameter, th, ds)) { continue; }
                if (!(ds.radius > diskInner && ds.radius < diskOuter)) { continue; }
                // 穿越点与该处速度：平面内 (s, z) 沿像素径向旋转回 3D
                float s = ds.radius * sin(th);
                float zz = ds.radius * cos(th);
                float3 crossPoint = float3(radial * s, zz);
                float3 crossVelocity = float3(radial * ds.vs, ds.vz);
                DiskShade shade = shadeDiskCrossing(
                    crossPoint, crossVelocity, diskNormal, diskAxis,
                    spinDirection, spinSpeed, diskInner, diskOuter, time, transmittance);
                emission += shade.emissionAdd;
                transmittance *= 1.0 - shade.opacity;
            }
        }
    } else {
        // 加速度 a = -(3/2) h^2 x / r^5 里的常量系数，整条光线不变，提到循环外
        float accelCoeff = -1.5 * dot(rayPoint, rayPoint);
        // 远逃判据的比较值也是常量，避免每步重算
        float farBound = 4.0 * cameraDistance * cameraDistance;

        // 盘平面：法线绕屏幕 x 轴倾斜 kDiskIncl
        float cosIncl = cos(kDiskIncl);
        float sinIncl = sin(kDiskIncl);
        float3 diskNormal = float3(0.0, sinIncl, cosIncl);
        float3 diskAxis = float3(0.0, cosIncl, -sinIncl); // 与 (x̂, diskAxis, diskNormal) 构成正交系
        float spinDirection = kDiskSpeed < 0.0 ? -1.0 : 1.0;
        float spinSpeed = abs(kDiskSpeed);

        float planeDistancePrev = dot(position, diskNormal);
        float3 positionPrev = position;

        for (int i = 0; i < N_STEPS; i++) {
            float radiusSquared = dot(position, position);
            if (radiusSquared < 1.0) {                          // 穿过视界
                captured = true;
                break;
            }
            if (position.z < -cameraDistance && velocity.z < 0.0) {  // 从后方逃逸
                break;
            }
            if (radiusSquared > farBound) {                     // 被甩向远处
                break;
            }
            // 1/r 用 rsqrt 求，避免 sqrt + 除法：a = accelCoeff * x / r^5 = accelCoeff * x * (1/r)^5
            float invRadius = rsqrt(radiusSquared);
            float radius = radiusSquared * invRadius;           // = sqrt(radiusSquared)
            // 步长随半径变化：光子球附近细，远处粗（偏折按 1/r^4 衰减，
            // 远处放大步长可把 N_STEPS 预算留给强弯曲区域）
            float stepSize = clamp(0.16 * radius, 0.03, 1.5);
            // 蛙跳积分（kick-drift-kick）能让接近临界的轨道保持稳定
            float invRadius5 = invRadius * invRadius;
            invRadius5 = invRadius5 * invRadius5 * invRadius;   // (1/r)^5
            float3 acceleration = accelCoeff * position * invRadius5;
            velocity += acceleration * (0.5 * stepSize);
            position += velocity * stepSize;
            radiusSquared = dot(position, position);
            invRadius = rsqrt(radiusSquared);
            invRadius5 = invRadius * invRadius;
            invRadius5 = invRadius5 * invRadius5 * invRadius;   // (1/r)^5
            acceleration = accelCoeff * position * invRadius5;
            velocity += acceleration * (0.5 * stepSize);

            // ---- 薄盘穿越：光线穿过了盘平面 ----
            // 穿越处调用与查表路径共用的 shadeDiskCrossing，保证两条路径盘光完全一致。
            float planeDistance = dot(position, diskNormal);
            if (planeDistance * planeDistancePrev < 0.0 && transmittance > 0.02) {
                float crossFraction = planeDistancePrev / (planeDistancePrev - planeDistance);
                float3 crossPoint = mix(positionPrev, position, crossFraction);
                DiskShade shade = shadeDiskCrossing(
                    crossPoint, velocity, diskNormal, diskAxis,
                    spinDirection, spinSpeed, diskInner, diskOuter, time, transmittance);
                emission += shade.emissionAdd;
                transmittance *= 1.0 - shade.opacity;
            }
            planeDistancePrev = planeDistance;
            positionPrev = position;
        }
        // 预算耗尽时仍缠绕在光子球附近的光线，等同于被捕获
        if (!captured && dot(position, position) < 4.0) {
            captured = true;
        }
    }

    // ---- 背景：逃逸光线来自哪里？ ----
    float3 background = float3(0.0);
    float backgroundAlpha = 0.0;
    if (!captured) {
        float3 direction = normalize(velocity);
        background += starfield(direction, uniforms.time) * kStarGain * window;
        backgroundAlpha = max(backgroundAlpha, min(1.0, max(background.r, max(background.g, background.b))));
        if (direction.z < -0.05) {
            // 把逃逸后的直线光线投影到 z = -kLensDepth 的桌面天空平面，再映射回屏幕
            float planeHit = (-kLensDepth - position.z) / direction.z;
            float3 hitPoint = position + direction * planeHit;
            float2 planePoint = rotate2D(hitPoint.xy, -kDiskRoll) / worldScale;
            float2 screenPoint = float2(planePoint.x, -planePoint.y);
            // 被淡出的只是位移量，颜色始终保留，
            // 这样连续的畸变场在远场交界处不会留下接缝
            float2 sampleUV = mirrorUV(center + (p + (screenPoint - p) * window) / float2(aspect, 1.0));
            // 偏折超过约 90° 的光线永远到不了黑洞背后的天空平面，
            // 让它们淡入星场而不是采样到无意义的位置
            float toward = smoothstep(0.05, 0.35, -direction.z);
            if (hasScreen) {
                background += screenTexture.sample(screenSampler, sampleUV).rgb * toward;
                backgroundAlpha = 1.0;
            }
        }
    }

    // 盘光是 HDR，需要在（未被改动的）桌面采样之上做色调映射
    float3 diskLight = float3(1.0) - exp(-emission * kExposure);
    float3 color = background * transmittance + diskLight;

    if (hasScreen) {
        // 混合状态为预乘 alpha，因此淡出覆盖时 RGB 必须同乘 coverage
        return float4(color * coverage, coverage);
    }

    // 无屏幕捕获权限时降级为透明覆盖：只绘制盘光、星场和黑洞阴影本身。
    // 阴影区域用不透明黑遮住桌面，才能读出“洞”的形状。
    float diskAlpha = min(1.0, max(diskLight.r, max(diskLight.g, diskLight.b)));
    float shadowAlpha = captured
        ? smoothstep(maxImpact, B_CRIT, impactParameter)
        : 0.0;
    float alpha = clamp(max(max(diskAlpha, shadowAlpha), backgroundAlpha * transmittance), 0.0, 1.0)
        * coverage;
    return float4(color * coverage, alpha);
}
