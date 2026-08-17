import Cocoa
import Carbon
import CoreMedia
import CoreVideo
import MetalKit
import QuartzCore
import ScreenCaptureKit

private let quitHotKeySignature: OSType = 0x42484F4C
private let quitHotKeyID: UInt32 = 1
private let prefsHotKeyID: UInt32 = 2

// 打开首选项面板的回调，由 AppDelegate 注入。热键回调是 C 函数、无法直接持有
// Swift 对象，故用全局闭包搭桥，并确保在主线程执行。
@MainActor private var openPreferencesAction: (() -> Void)?

private func handleGlobalHotKey(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == quitHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    switch identifier.id {
    case quitHotKeyID:
        NSApp.terminate(nil)
        return noErr
    case prefsHotKeyID:
        DispatchQueue.main.async { MainActor.assumeIsolated { openPreferencesAction?() } }
        return noErr
    default:
        return OSStatus(eventNotHandledErr)
    }
}

private struct RenderUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var radius: Float
    var screenResolution: SIMD2<Float>
    var seed: SIMD2<Float>
    var driftSpeed: Float
}

// 从命令行读取某个 0-10 刻度参数：存在且可解析时返回截断到 [0,10] 的刻度值，
// 缺省或非法时返回 nil（表示“未指定”，由存储值或默认值接管）。
private func argScale(_ arguments: [String], _ key: String) -> Float? {
    for (index, argument) in arguments.enumerated()
    where argument == key && index + 1 < arguments.count {
        if let scale = Float(arguments[index + 1]) {
            return min(max(scale, 0), 10)
        }
    }
    return nil
}

// 黑洞尺寸：0-10 刻度映射到阴影半径占屏幕高度的比例。
// 采用分段线性，锚定三点：0→minValue、5→midValue、10→maxValue，
// 让刻度 5 稳定保持默认观感，同时把上半段拉到更大的上限。
// 数值越大，透镜场半径越大，GPU 采样开销越高。
private enum BlackHoleSize {
    static let minValue: Float = 0.02
    static let midValue: Float = 0.055   // 刻度 5，历史默认观感
    static let maxValue: Float = 0.16    // 刻度 10，约屏高的一半

    // 命令行刻度，缺省返回 nil
    static func scale(from arguments: [String]) -> Float? { argScale(arguments, "--size") }

    static func radius(forScale scale: Float) -> Float {
        let clamped = min(max(scale, 0), 10)
        if clamped <= 5 {
            return minValue + (midValue - minValue) * (clamped / 5)
        }
        return midValue + (maxValue - midValue) * ((clamped - 5) / 5)
    }
}

// 漂移速度：0-10 刻度映射到速度倍率 0-2.0（5→1.0），仅影响漫游，不影响吸积盘转速。
private enum DriftSpeed {
    static func scale(from arguments: [String]) -> Float? { argScale(arguments, "--speed") }

    static func multiplier(forScale scale: Float) -> Float {
        min(max(scale, 0), 10) / 10 * 2.0
    }
}

// 渲染的屏幕数量：--screens N，限制在前 N 块显示器上渲染黑洞。
// 至少 1 块；命令行缺省或非法时返回 nil（表示“未指定”）。
private enum ScreenCount {
    static func value(from arguments: [String]) -> Int? {
        for (index, argument) in arguments.enumerated()
        where argument == "--screens" && index + 1 < arguments.count {
            if let value = Int(arguments[index + 1]) {
                return max(value, 1)
            }
        }
        return nil
    }
}

// 吸附增大速率：0-10 刻度控制黑洞随时间“吞噬”桌面而膨胀的快慢。
// 0 关闭（尺寸恒定）；数值越大，半径逼近上限越快。
private enum GrowthRate {
    static func scale(from arguments: [String]) -> Float? { argScale(arguments, "--growth") }

    static func rate(forScale scale: Float) -> Float {
        // 映射到指数增长速率（1/秒）。时间常数 τ = 1/rate：
        // 10→rate 0.05（τ≈20 秒），逼近上限约需 1 分钟；0→关闭。
        min(max(scale, 0), 10) / 10 * 0.05
    }
}

// 运行时可调的共享设置：尺寸/速度/增大以 0-10 刻度存储，屏幕数量单独存。
// 所有渲染器共享同一实例并逐帧读取，故首选项面板拖动滑块即时生效；
// 全部持久化到 UserDefaults，下次启动自动恢复。命令行参数存在时覆盖并持久化。
// 仅在主线程访问（渲染器 draw 与首选项面板都在主线程），UserDefaults 本身线程安全。
private final class Settings: @unchecked Sendable {
    private enum Keys {
        static let size = "sizeScale"
        static let speed = "speedScale"
        static let growth = "growthScale"
        static let screens = "screenLimit"   // 0 表示所有屏幕
    }

    private let store = UserDefaults.standard
    // 屏幕数量变化需要重建窗口，由 AppDelegate 注入
    var onScreenLimitChanged: (() -> Void)?

    var sizeScale: Float { didSet { store.set(sizeScale, forKey: Keys.size) } }
    var speedScale: Float { didSet { store.set(speedScale, forKey: Keys.speed) } }
    var growthScale: Float { didSet { store.set(growthScale, forKey: Keys.growth) } }
    // nil 表示所有屏幕
    var screenLimit: Int? {
        didSet {
            store.set(screenLimit ?? 0, forKey: Keys.screens)
            onScreenLimitChanged?()
        }
    }

    // 供渲染器逐帧读取的物理值
    var radius: Float { BlackHoleSize.radius(forScale: sizeScale) }
    var driftSpeed: Float { DriftSpeed.multiplier(forScale: speedScale) }
    var growthRate: Float { GrowthRate.rate(forScale: growthScale) }

    init(arguments: [String]) {
        // 存储值优先，缺省回退到默认刻度（尺寸/速度 5，增大 0）
        sizeScale = store.object(forKey: Keys.size) != nil ? store.float(forKey: Keys.size) : 5
        speedScale = store.object(forKey: Keys.speed) != nil ? store.float(forKey: Keys.speed) : 5
        growthScale = store.object(forKey: Keys.growth) != nil ? store.float(forKey: Keys.growth) : 0
        let storedScreens = store.integer(forKey: Keys.screens)   // 缺省 0
        screenLimit = storedScreens <= 0 ? nil : storedScreens

        // 命令行参数存在时覆盖
        if let s = BlackHoleSize.scale(from: arguments) { sizeScale = s }
        if let s = DriftSpeed.scale(from: arguments) { speedScale = s }
        if let s = GrowthRate.scale(from: arguments) { growthScale = s }
        if let n = ScreenCount.value(from: arguments) { screenLimit = n }

        // init 内赋值不触发 didSet，这里统一持久化一次（含命令行覆盖）
        store.set(sizeScale, forKey: Keys.size)
        store.set(speedScale, forKey: Keys.speed)
        store.set(growthScale, forKey: Keys.growth)
        store.set(screenLimit ?? 0, forKey: Keys.screens)
    }
}

private enum RendererError: LocalizedError {
    case noMetalDevice
    case noTextureCache
    case missingShaderSource(String)
    case missingShaderFunction(String)
    case lutAllocationFailed

    var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "Metal is unavailable on this Mac"
        case .noTextureCache:
            return "Unable to create the screen texture cache"
        case .missingShaderSource(let path):
            return "Unable to load the Metal shader source at \(path)"
        case .missingShaderFunction(let name):
            return "The Metal shader function \(name) is missing"
        case .lutAllocationFailed:
            return "Unable to allocate the geodesic lookup tables"
        }
    }
}

// 预计算逃逸测地线查找表（近似方案 A 第一步：只替掉“逃逸几何”，不碰吸积盘）。
//
// 物理事实：史瓦西是中心力场，光子轨道恒在一个平面内，因此“平行入射、冲击参数为 b
// 的光线最终逃向何方”只是 b 的一元函数。据此在启动时用 CPU 复刻着色器的积分器
// （同样的 N_STEPS、自适应步长、蛙跳），把逃逸终点状态制成一维表：
//
//   * 透镜表 lens[b]  —— 光线自身 2D 平面内的终点 (px, pz) 与归一化方向 (dx, dz)。
//     着色器按像素方位角把它旋转回 3D，再做与原来完全一致的天空平面投影。
//   * 盘门控表 gate[方位角] —— 每个方位角上“可能穿过吸积盘”的 b 区间 [lo, hi]。
//     盘因倾斜+滚转在屏幕上不是同心圆，足迹随方位角变化。区间之外的光线保证碰不到盘，
//     可安全跳过 48 步积分、直接查透镜表；区间之内仍走完整积分累加盘光。
//
// 表与屏幕分辨率、黑洞尺寸/位置、屏幕数量全部无关（用的是史瓦西半径下的纯物理量），
// 故只算一次、所有屏幕共享，内存约 16KB(透镜) + 1.4KB(门控)。
//
// ⚠️ 下列常量必须与 BlackHoleShaders.metal 中的物理常量保持一致，改一处要同步另一处：
//   bCrit=B_CRIT, nSteps=N_STEPS, diskIncl=kDiskIncl, diskInner=max(kDiskInner,1.6),
//   diskOuter=max(kDiskOuter,diskInner+0.5), cameraDistance=max(14,kDiskOuter+5),
//   maxImpact=kDiskOuter+3, lensSamples=kLensSamples, gateAzimuths=kGateAzimuths。
private enum GeodesicLUT {
    static let bCrit: Float = 2.5980762
    static let nSteps = 48
    static let diskInner: Float = 1.8            // max(kDiskInner=1.8, 1.6)
    static let diskOuter: Float = 8.0            // max(kDiskOuter=8.0, diskInner+0.5)
    static let diskIncl: Float = 1.5
    static let cameraDistance: Float = 14.0      // max(14, kDiskOuter+5)
    static let maxImpact: Float = 11.0           // kDiskOuter + 3
    static let lensSamples = 1024                // 需与着色器 kLensSamples 一致
    static let gateAzimuths = 180                // 需与着色器 kGateAzimuths 一致
    // 吸积盘二维查表（方案A第二步）：把“可能穿盘”的单次穿越像素也改成查表，
    // 免去逐像素积分。表按 (b, θ) 索引，θ 为光线在自身 2D 轨道平面内的累积极角。
    static let diskBSamples = 256                // 需与着色器 kDiskBSamples 一致
    static let diskThetaSamples = 256            // 需与着色器 kDiskThetaSamples 一致
    // 混合门限：b < gateBFactor·bCrit 的光子环环带仍走完整积分（含全部多次穿越）；
    // b ≥ 该门限的单次穿盘像素才用盘表重建。验证表明多次穿越像素全部落在门限以内。
    static let gateBFactor: Float = 1.5
    static let diskThetaMax: Float = 1.5 * Float.pi   // θ 采样上限，覆盖近侧+远侧穿越
    // θ 采样下界：入射极角 atan2(bCrit, cameraDistance)（随 b 略变，取 bCrit 处为基准）
    static var diskTheta0: Float { atan2f(bCrit, cameraDistance) }

    // 复刻着色器的单条光线积分，返回逃逸终点在其 2D 轨道平面内的状态。
    // (px, pz) 为终点位置：px 是平面内横向（初始沿 +冲击参数方向）、pz 是纵深；
    // (dx, dz) 为归一化终点方向。captured 为真表示落入视界（本表定义域内不应出现）。
    private static func integrateLens(_ b: Float) -> (px: Float, pz: Float, dx: Float, dz: Float, captured: Bool) {
        let accelCoeff = -1.5 * b * b
        let farBound = 4.0 * cameraDistance * cameraDistance
        var px = b, pz = cameraDistance
        var vx: Float = 0, vz: Float = -1
        var captured = false
        for _ in 0..<nSteps {
            var r2 = px * px + pz * pz
            if r2 < 1.0 { captured = true; break }
            if pz < -cameraDistance && vz < 0 { break }
            if r2 > farBound { break }
            let invR = 1.0 / sqrtf(r2)
            let radius = r2 * invR
            let step = min(max(0.16 * radius, 0.03), 1.5)
            var invR5 = invR * invR; invR5 = invR5 * invR5 * invR
            vx += accelCoeff * px * invR5 * (0.5 * step)
            vz += accelCoeff * pz * invR5 * (0.5 * step)
            px += vx * step; pz += vz * step
            r2 = px * px + pz * pz
            let invRb = 1.0 / sqrtf(r2)
            var invR5b = invRb * invRb; invR5b = invR5b * invR5b * invRb
            vx += accelCoeff * px * invR5b * (0.5 * step)
            vz += accelCoeff * pz * invR5b * (0.5 * step)
        }
        if !captured && (px * px + pz * pz) < 4.0 { captured = true }
        let invLen = 1.0 / sqrtf(vx * vx + vz * vz)
        return (px, pz, vx * invLen, vz * invLen, captured)
    }

    // 判断给定屏幕平面坐标（已乘 worldScale、已施加滚转的 rayPoint）的光线是否穿过吸积盘环带。
    private static func touchesDisk(_ rx: Float, _ ry: Float) -> Bool {
        let cosI = cosf(diskIncl), sinI = sinf(diskIncl)
        // 盘法线 (0, sinI, cosI)
        let nx: Float = 0, ny = sinI, nz = cosI
        var pxx = rx, pyy = ry, pzz = cameraDistance
        var vx: Float = 0, vy: Float = 0, vz: Float = -1
        let accelCoeff = -1.5 * (rx * rx + ry * ry)
        let farBound = 4.0 * cameraDistance * cameraDistance
        var planePrev = pxx * nx + pyy * ny + pzz * nz
        var ppx = pxx, ppy = pyy, ppz = pzz
        for _ in 0..<nSteps {
            var r2 = pxx * pxx + pyy * pyy + pzz * pzz
            if r2 < 1.0 { return false }
            if pzz < -cameraDistance && vz < 0 { break }
            if r2 > farBound { break }
            let invR = 1.0 / sqrtf(r2)
            let radius = r2 * invR
            let step = min(max(0.16 * radius, 0.03), 1.5)
            var invR5 = invR * invR; invR5 = invR5 * invR5 * invR
            vx += accelCoeff * pxx * invR5 * (0.5 * step)
            vy += accelCoeff * pyy * invR5 * (0.5 * step)
            vz += accelCoeff * pzz * invR5 * (0.5 * step)
            pxx += vx * step; pyy += vy * step; pzz += vz * step
            r2 = pxx * pxx + pyy * pyy + pzz * pzz
            let invRb = 1.0 / sqrtf(r2)
            var invR5b = invRb * invRb; invR5b = invR5b * invR5b * invRb
            vx += accelCoeff * pxx * invR5b * (0.5 * step)
            vy += accelCoeff * pyy * invR5b * (0.5 * step)
            vz += accelCoeff * pzz * invR5b * (0.5 * step)
            let planeDist = pxx * nx + pyy * ny + pzz * nz
            if planeDist * planePrev < 0 {
                let frac = planePrev / (planePrev - planeDist)
                let cx = ppx + (pxx - ppx) * frac
                let cy = ppy + (pyy - ppy) * frac
                let cz = ppz + (pzz - ppz) * frac
                let cr = sqrtf(cx * cx + cy * cy + cz * cz)
                if cr > diskInner && cr < diskOuter { return true }
            }
            planePrev = planeDist; ppx = pxx; ppy = pyy; ppz = pzz
        }
        return false
    }

    // 透镜表：lensSamples 个 SIMD4<Float>(px, pz, dx, dz)，b 在 [bCrit, maxImpact] 上等距采样
    static func buildLensTable() -> [SIMD4<Float>] {
        var table = [SIMD4<Float>](repeating: .zero, count: lensSamples)
        for i in 0..<lensSamples {
            let b = bCrit + (maxImpact - bCrit) * Float(i) / Float(lensSamples - 1)
            let s = integrateLens(b)
            table[i] = SIMD4(s.px, s.pz, s.dx, s.dz)
        }
        return table
    }

    // 盘门控表：gateAzimuths 个 SIMD2<Float>(loB, hiB)。无盘的方位存 (∞, 0) → 判定恒为“不碰盘”。
    // 保守外扩：半径向外扩两个扫描格宽，并对相邻方位桶取并，抵消离散化漏判。
    static func buildGateTable() -> [SIMD2<Float>] {
        let bScan = 600
        var lo = [Float](repeating: .greatestFiniteMagnitude, count: gateAzimuths)
        var hi = [Float](repeating: 0, count: gateAzimuths)
        for ai in 0..<gateAzimuths {
            let az = 2 * Float.pi * (Float(ai) + 0.5) / Float(gateAzimuths)
            let cx = cosf(az), cy = sinf(az)
            for bi in 0..<bScan {
                let b = bCrit + (maxImpact - bCrit) * (Float(bi) + 0.5) / Float(bScan)
                if touchesDisk(b * cx, b * cy) {
                    lo[ai] = min(lo[ai], b); hi[ai] = max(hi[ai], b)
                }
            }
        }
        let pad = (maxImpact - bCrit) / Float(bScan) * 2
        var table = [SIMD2<Float>](repeating: .zero, count: gateAzimuths)
        for ai in 0..<gateAzimuths {
            var l = lo[ai], h = hi[ai]
            for d in [-1, 1] {
                let j = (ai + d + gateAzimuths) % gateAzimuths
                if hi[j] > 0 { l = min(l, lo[j]); h = max(h, hi[j]) }
            }
            if h == 0 {
                table[ai] = SIMD2(.greatestFiniteMagnitude, 0)   // 该方位无盘：恒判“不碰盘”
            } else {
                table[ai] = SIMD2(max(bCrit, l - pad), h + pad)
            }
        }
        return table
    }

    // 单条光线在其 2D 轨道平面内的积分：坐标 (s, z)，s 沿像素径向、z 为纵深。
    // 返回沿轨迹的 (累积极角 θ, 半径 r, 归一化速度 vs, vz) 序列，θ 已 unwrap 单调递增。
    // 与 integrateLens 是同一物理，只是额外记录中间状态供盘表按 θ 采样。
    private static func planarTrajectory(_ b: Float)
        -> (theta: [Float], r: [Float], vs: [Float], vz: [Float]) {
        let accelCoeff = -1.5 * b * b
        let farBound = 4.0 * cameraDistance * cameraDistance
        var s = b, z = cameraDistance
        var vs: Float = 0, vz: Float = -1
        var thetas: [Float] = [], radii: [Float] = [], velS: [Float] = [], velZ: [Float] = []
        var prevTheta = atan2f(s, z)
        var unwrapped = prevTheta
        func pushVelocity() {
            let invLen = 1.0 / sqrtf(vs * vs + vz * vz)
            velS.append(vs * invLen); velZ.append(vz * invLen)
        }
        thetas.append(unwrapped); radii.append(sqrtf(s * s + z * z)); pushVelocity()
        for _ in 0..<nSteps {
            var r2 = s * s + z * z
            if r2 < 1.0 { break }
            if z < -cameraDistance && vz < 0 { break }
            if r2 > farBound { break }
            let invR = 1.0 / sqrtf(r2)
            let radius = r2 * invR
            let step = min(max(0.16 * radius, 0.03), 1.5)
            var invR5 = invR * invR; invR5 = invR5 * invR5 * invR
            vs += accelCoeff * s * invR5 * (0.5 * step)
            vz += accelCoeff * z * invR5 * (0.5 * step)
            s += vs * step; z += vz * step
            r2 = s * s + z * z
            let invRb = 1.0 / sqrtf(r2)
            var invR5b = invRb * invRb; invR5b = invR5b * invR5b * invRb
            vs += accelCoeff * s * invR5b * (0.5 * step)
            vz += accelCoeff * z * invR5b * (0.5 * step)
            // θ unwrap：把每步增量归一到 (−π, π] 再累加，得到单调极角
            let theta = atan2f(s, z)
            var delta = theta - prevTheta
            if delta < -Float.pi { delta += 2 * Float.pi }
            if delta > Float.pi { delta -= 2 * Float.pi }
            unwrapped += delta; prevTheta = theta
            thetas.append(unwrapped); radii.append(sqrtf(r2)); pushVelocity()
        }
        return (thetas, radii, velS, velZ)
    }

    // 在单调序列 xs 上对 q 做线性插值取 ys；q 超出范围返回 nil。
    private static func interpolate(_ xs: [Float], _ ys: [Float], _ q: Float) -> Float? {
        if xs.count < 2 || q < xs[0] || q > xs[xs.count - 1] { return nil }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= q { lo = mid } else { hi = mid }
        }
        let t = (q - xs[lo]) / (xs[hi] - xs[lo])
        return ys[lo] * (1 - t) + ys[hi] * t
    }

    // 吸积盘二维表：diskBSamples × diskThetaSamples 个 SIMD4<Float>(r, vs, vz, 0)。
    // 行索引对应 b∈[bCrit, maxImpact]，列索引对应 θ∈[diskTheta0, diskThetaMax]。
    // θ 超出该 b 实际 unwrap 范围处存 0（着色器据此判定“该 (b,θ) 无穿越”）。
    static func buildDiskTable() -> [SIMD4<Float>] {
        let theta0 = diskTheta0
        var table = [SIMD4<Float>](repeating: .zero, count: diskBSamples * diskThetaSamples)
        for bi in 0..<diskBSamples {
            let b = bCrit + (maxImpact - bCrit) * Float(bi) / Float(diskBSamples - 1)
            let traj = planarTrajectory(b)
            for tj in 0..<diskThetaSamples {
                let theta = theta0 + (diskThetaMax - theta0) * Float(tj) / Float(diskThetaSamples - 1)
                guard let r = interpolate(traj.theta, traj.r, theta),
                      let vs = interpolate(traj.theta, traj.vs, theta),
                      let vz = interpolate(traj.theta, traj.vz, theta) else {
                    continue   // 保持 .zero，表示该 (b,θ) 无有效穿越
                }
                table[bi * diskThetaSamples + tj] = SIMD4(r, vs, vz, 0)
            }
        }
        return table
    }
}

private final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // 捕获帧率：桌面内容与黑洞漂移都很慢，基础 30fps 捕获肉眼已无差，
    // 却把 ScreenCaptureKit 的整屏抓取 + 色彩转换 CPU 开销直接对半砍；
    // 空闲时进一步降到 15fps。捕获帧率与渲染帧率各自独立，由渲染器空闲逻辑统一驱动。
    static let activeCaptureFPS = 30
    static let idleCaptureFPS = 15

    private let frameQueue = DispatchQueue(label: "blackhole.screen-capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var stream: SCStream?
    private var generation: UInt64 = 0
    // 保存 configuration 以便运行时通过 updateConfiguration 改捕获帧率（无需重建流）
    private var configuration: SCStreamConfiguration?
    private var currentCaptureFPS = 0

    func start(displayID: CGDirectDisplayID, width: Int, height: Int) async {
        let generation = stateLock.withLock {
            self.generation &+= 1
            return self.generation
        }

        do {
            let content = try await SCShareableContent.current
            guard isCurrent(generation) else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NSError(
                    domain: "BlackHoleOverlay",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The selected display is unavailable for capture"]
                )
            }

            let currentProcess = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: currentProcess,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ScreenCaptureSource.activeCaptureFPS))
            configuration.queueDepth = 3
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.shouldBeOpaque = true

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
            let shouldStart = stateLock.withLock {
                guard self.generation == generation else { return false }
                self.stream = stream
                self.configuration = configuration
                self.currentCaptureFPS = ScreenCaptureSource.activeCaptureFPS
                return true
            }
            guard shouldStart else { return }

            try await stream.startCapture()
            guard isCurrent(generation, stream: stream) else {
                try? await stream.stopCapture()
                return
            }
        } catch {
            let shouldReport = stateLock.withLock {
                guard self.generation == generation else { return false }
                self.stream = nil
                latestPixelBuffer = nil
                return true
            }
            guard shouldReport else { return }
            fputs(
                "Screen capture is unavailable; rendering without desktop distortion: \(error.localizedDescription)\n",
                stderr
            )
        }
    }

    func stop() {
        let stream = stateLock.withLock {
            generation &+= 1
            let stream = self.stream
            self.stream = nil
            latestPixelBuffer = nil
            configuration = nil
            currentCaptureFPS = 0
            return stream
        }
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
        }
    }

    // 运行时调整捕获帧率：仅在帧率变化时通过 updateConfiguration 生效（无需重建流）。
    // 由渲染器的空闲逻辑驱动，与渲染帧率联动：活跃 30fps、空闲 15fps。
    func updateCaptureFPS(_ fps: Int) {
        let target: (stream: SCStream, configuration: SCStreamConfiguration)? = stateLock.withLock {
            guard let stream, let configuration, currentCaptureFPS != fps else { return nil }
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            currentCaptureFPS = fps
            return (stream, configuration)
        }
        guard let target else { return }
        Task {
            try? await target.stream.updateConfiguration(target.configuration)
        }
    }

    func pixelBuffer() -> CVPixelBuffer? {
        stateLock.withLock { latestPixelBuffer }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        stateLock.withLock {
            guard self.stream === stream else { return }
            latestPixelBuffer = pixelBuffer
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let shouldReport = stateLock.withLock {
            guard self.stream === stream else { return false }
            generation &+= 1
            self.stream = nil
            latestPixelBuffer = nil
            return true
        }
        guard shouldReport else { return }
        fputs("Screen capture stopped: \(error.localizedDescription)\n", stderr)
    }

    private func isCurrent(_ generation: UInt64, stream: SCStream? = nil) -> Bool {
        stateLock.withLock {
            guard self.generation == generation else { return false }
            guard let stream else { return true }
            return self.stream === stream
        }
    }
}

// 共享渲染资源：Metal 设备与编译好的着色器 library 只在启动时创建一次，
// 供所有屏幕的渲染器复用。避免每块屏幕都重复读取着色器源码并调用
// makeLibrary(source:) 编译（一次编译约数百毫秒），减少多屏启动开销。
private final class RenderResources {
    let device: MTLDevice
    let library: MTLLibrary
    // 预计算的逃逸测地线查找表，所有屏幕共享（见 GeodesicLUT 说明）
    let lensTable: MTLBuffer
    let gateTable: MTLBuffer
    // 吸积盘二维查表 (r, vs, vz)，所有屏幕共享（方案A第二步）
    let diskTable: MTLBuffer

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noMetalDevice
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let shaderURL = executableURL.deletingLastPathComponent().appendingPathComponent("BlackHoleShaders.metal")
        guard let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            throw RendererError.missingShaderSource(shaderURL.path)
        }
        self.device = device
        self.library = try device.makeLibrary(source: shaderSource, options: nil)

        // 启动时构建一次逃逸测地线查找表（CPU 数值积分），上传为共享只读缓冲。
        let lens = GeodesicLUT.buildLensTable()
        let gate = GeodesicLUT.buildGateTable()
        let disk = GeodesicLUT.buildDiskTable()
        guard let lensBuffer = device.makeBuffer(
                bytes: lens,
                length: MemoryLayout<SIMD4<Float>>.stride * lens.count,
                options: .storageModeShared),
              let gateBuffer = device.makeBuffer(
                bytes: gate,
                length: MemoryLayout<SIMD2<Float>>.stride * gate.count,
                options: .storageModeShared),
              let diskBuffer = device.makeBuffer(
                bytes: disk,
                length: MemoryLayout<SIMD4<Float>>.stride * disk.count,
                options: .storageModeShared)
        else {
            throw RendererError.lutAllocationFailed
        }
        self.lensTable = lensBuffer
        self.gateTable = gateBuffer
        self.diskTable = diskBuffer
    }
}

private final class BlackHoleRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let captureSource: ScreenCaptureSource
    private let textureCache: CVMetalTextureCache
    // 共享的逃逸测地线查找表（由 RenderResources 构建，所有屏幕复用同一份缓冲）
    private let lensTable: MTLBuffer
    private let gateTable: MTLBuffer
    private let diskTable: MTLBuffer
    private let startTime = CACurrentMediaTime()
    // 运行时可调参数的共享来源：尺寸/速度/增大均逐帧从这里读取，
    // 因此首选项面板拖动滑块即时生效。
    private let settings: Settings
    // 吸附增大：settings.growthRate 为 [0,1] 速率（0 关闭）；黑洞半径随时间从
    // 当前尺寸渐近逼近上限，模拟持续吞噬桌面而膨胀。上限同时兜住 GPU 采样开销。
    private let maxRadius: Float
    private var currentRadius: Float
    private var lastGrowthTime = CACurrentMediaTime()
    // 输入空闲降帧：用户超过 idleThreshold 秒无鼠标/键盘操作时降到 idleFPS 省电，
    // 一有输入立刻回到 activeFPS。黑洞漂移与吸积盘旋转是时间驱动的，降帧只影响
    // 平滑度、不改变动画速度，因此空闲时仍连续动，只是每秒少渲染几帧。
    private static let activeFPS = 60
    private static let idleFPS = 30
    private static let idleThreshold = 5.0   // 无输入超过此秒数即判为空闲
    private var currentFPS = 0
    // 每个渲染器（每块屏幕）一个随机种子：seed.x 为随机相位，seed.y 为随机时间偏移，
    // 令每块屏幕的漂移轨迹互不相同，且每次启动都不一样。
    private let seed = SIMD2<Float>(
        Float.random(in: 0 ..< (2 * Float.pi)),
        Float.random(in: 0 ..< 1000)
    )

    init(view: MTKView, resources: RenderResources, captureSource: ScreenCaptureSource, settings: Settings) throws {
        self.settings = settings
        self.currentRadius = settings.radius
        // 增大上限对齐到尺寸刻度的最大值：吸附能长到的最大体积，
        // 恰好等于手动能设的最大尺寸，概念统一，也兜住重采样 GPU 开销。
        self.maxRadius = BlackHoleSize.maxValue
        let device = resources.device
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.noMetalDevice
        }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache
        else {
            throw RendererError.noTextureCache
        }

        // 复用启动时编译好的共享 library，不再逐屏读取源码重新编译
        let library = resources.library
        guard let vertexFunction = library.makeFunction(name: "blackHoleVertex") else {
            throw RendererError.missingShaderFunction("blackHoleVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "blackHoleFragment") else {
            throw RendererError.missingShaderFunction("blackHoleFragment")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .one
        colorAttachment.sourceAlphaBlendFactor = .one
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.commandQueue = commandQueue
        self.captureSource = captureSource
        self.textureCache = textureCache
        self.lensTable = resources.lensTable
        self.gateTable = resources.gateTable
        self.diskTable = resources.diskTable
        pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }

        var screenTexture: MTLTexture?
        var retainedScreenTexture: CVMetalTexture?
        if let device = view.device, let pixelBuffer = captureSource.pixelBuffer() {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
            if status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
                retainedScreenTexture = cvTexture
                screenTexture = texture
            } else {
                CVMetalTextureCacheFlush(textureCache, 0)
                _ = device
            }
        }

        // 逐帧从共享设置读取，令首选项面板拖动滑块即时生效。
        let growthRate = settings.growthRate
        let driftSpeed = settings.driftSpeed
        // 吸附增大：按帧间 dt 累积（与帧率无关），半径以指数方式渐近逼近上限。
        // 关闭增大（growthRate 为 0）时，半径直接跟随尺寸滑块，故拖动尺寸即时生效；
        // 开启增大时，半径从当前值渐近逼近上限，不再受尺寸滑块直接控制。
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastGrowthTime, 0), 0.1))
        lastGrowthTime = now
        if growthRate > 0 {
            if currentRadius < maxRadius {
                currentRadius += (maxRadius - currentRadius) * growthRate * dt
                currentRadius = min(currentRadius, maxRadius)
            }
        } else {
            currentRadius = settings.radius
        }

        // 静止降帧：按全局输入空闲时间判断。距上次鼠标/键盘操作超过 idleThreshold
        // 秒就降到 idleFPS 省电，一有输入立刻回到 activeFPS。吸附增大过程中黑洞
        // 体积仍在变，视为活跃以保持膨胀平滑。
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
        let growing = growthRate > 0 && currentRadius < maxRadius
        let active = growing || idleSeconds < BlackHoleRenderer.idleThreshold
        let targetFPS = active ? BlackHoleRenderer.activeFPS : BlackHoleRenderer.idleFPS
        if targetFPS != currentFPS {
            currentFPS = targetFPS
            view.preferredFramesPerSecond = targetFPS
        }
        // 捕获帧率随空闲状态联动：活跃时 30fps、空闲时 15fps。这是 CPU 占用的主项——
        // ScreenCaptureKit 每帧整屏抓取 + 色彩转换，降捕获帧率比降渲染帧率更省 CPU。
        // updateCaptureFPS 内部按帧率变化做幂等判断，未变化时不触发流重配。
        captureSource.updateCaptureFPS(active
            ? ScreenCaptureSource.activeCaptureFPS
            : ScreenCaptureSource.idleCaptureFPS)

        let capturedWidth = Float(screenTexture?.width ?? 0)
        let capturedHeight = Float(screenTexture?.height ?? 0)
        var uniforms = RenderUniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: Float(now - startTime),
            radius: currentRadius,
            screenResolution: SIMD2(capturedWidth, capturedHeight),
            seed: seed,
            driftSpeed: driftSpeed
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        // 预计算的逃逸测地线查找表（所有屏幕共享的只读缓冲）
        encoder.setFragmentBuffer(lensTable, offset: 0, index: 1)
        encoder.setFragmentBuffer(gateTable, offset: 0, index: 2)
        encoder.setFragmentBuffer(diskTable, offset: 0, index: 3)
        encoder.setFragmentTexture(screenTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        _ = retainedScreenTexture
    }
}

private final class BlackHoleView: MTKView {
    private var blackHoleRenderer: BlackHoleRenderer?

    init(blackHoleFrame frame: CGRect, resources: RenderResources, captureSource: ScreenCaptureSource, settings: Settings) throws {
        // 复用共享设备，不再逐屏调用 MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: resources.device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        wantsLayer = true
        layer?.isOpaque = false

        let renderer = try BlackHoleRenderer(view: self, resources: resources, captureSource: captureSource, settings: settings)
        blackHoleRenderer = renderer
        delegate = renderer
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var captureSources: [ScreenCaptureSource] = []
    private var quitHotKey: EventHotKeyRef?
    private var quitHotKeyHandler: EventHandlerRef?
    private var prefsHotKey: EventHotKeyRef?
    // 运行时可调的共享设置：命令行参数 + UserDefaults 存储值，所有渲染器逐帧读取
    private let settings = Settings(arguments: CommandLine.arguments)
    // 首选项面板控制器（懒创建，重复打开复用同一实例）
    private var preferencesController: PreferencesWindowController?
    // 共享的 Metal 设备与编译好的着色器 library，启动时创建一次，供所有屏幕复用
    private var renderResources: RenderResources?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 屏幕数量改变需要重建窗口；其余参数逐帧读取，无需重建
        settings.onScreenLimitChanged = { [weak self] in self?.buildWindows() }
        registerGlobalHotKeys()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        buildWindows()
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureSources.forEach { $0.stop() }
        if let quitHotKey { UnregisterEventHotKey(quitHotKey) }
        if let prefsHotKey { UnregisterEventHotKey(prefsHotKey) }
        if let quitHotKeyHandler { RemoveEventHandler(quitHotKeyHandler) }
    }

    // 打开（或前置）首选项面板。由全局热键 ⌃⌥⌘, 触发。
    func showPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController(settings: settings)
        }
        // accessory 型 App 默认无法接收键盘焦点，临时提为 regular 让面板可交互
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
    }

    // 首选项面板关闭后收回到 accessory，重新隐藏 Dock 图标
    func preferencesDidClose() {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func screensChanged() {
        buildWindows()
    }

    private func buildWindows() {
        captureSources.forEach { $0.stop() }
        captureSources = []
        windows.forEach { $0.orderOut(nil) }

        // 编译一次共享着色器 library，之后所有屏幕复用（含显示器重排后重建窗口时）
        let resources: RenderResources
        do {
            if let existing = renderResources {
                resources = existing
            } else {
                resources = try RenderResources()
                renderResources = resources
            }
        } catch {
            fputs("Unable to prepare the Metal renderer: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        // 限制渲染的屏幕数量：默认所有屏幕，screenLimit 只取前 N 块
        let screens = settings.screenLimit.map { Array(NSScreen.screens.prefix($0)) } ?? NSScreen.screens
        windows = screens.compactMap { screen in
            do {
                guard let screenNumber = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber else {
                    return nil
                }
                let captureSource = ScreenCaptureSource()
                // screen.frame 是全局坐标。NSWindow 的 screen: 参数会把 contentRect
                // 当作该屏幕的相对坐标再加上屏幕原点，传入两者会让原点被叠加一次：
                // 副屏 (-121,1117) 会变成 (-242,2234)，窗口几乎完全移出该屏幕，
                // 只剩顶部一条与屏幕相交。这里传 nil，让 contentRect 保持全局坐标。
                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false,
                    screen: nil
                )
                // 显示器重新排列时 AppKit 可能自行搬动窗口，这里再钉一次几何
                window.setFrame(screen.frame, display: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.ignoresMouseEvents = true
                window.isReleasedWhenClosed = false
                window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                window.contentView = try BlackHoleView(
                    blackHoleFrame: NSRect(origin: .zero, size: screen.frame.size),
                    resources: resources,
                    captureSource: captureSource,
                    settings: settings
                )
                window.orderFrontRegardless()
                captureSources.append(captureSource)
                let pixelWidth = max(1, Int(screen.frame.width * screen.backingScaleFactor))
                let pixelHeight = max(1, Int(screen.frame.height * screen.backingScaleFactor))
                let displayID = CGDirectDisplayID(screenNumber.uint32Value)
                Task {
                    await captureSource.start(displayID: displayID, width: pixelWidth, height: pixelHeight)
                }
                return window
            } catch {
                fputs("Unable to create the black hole renderer: \(error.localizedDescription)\n", stderr)
                return nil
            }
        }

        if windows.isEmpty {
            NSApp.terminate(nil)
        }
    }

    private func registerGlobalHotKeys() {
        // 注入首选项热键回调（供 C 热键处理函数调用）
        openPreferencesAction = { [weak self] in self?.showPreferences() }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), handleGlobalHotKey, 1, &eventType, nil, &quitHotKeyHandler
        )
        guard handlerStatus == noErr else {
            fputs("Unable to install the global shortcuts. Use Control-C in Terminal to exit.\n", stderr)
            return
        }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)

        // 退出：⌃⌥⌘.
        let quitID = EventHotKeyID(signature: quitHotKeySignature, id: quitHotKeyID)
        if RegisterEventHotKey(
            UInt32(kVK_ANSI_Period), modifiers, quitID, GetApplicationEventTarget(), 0, &quitHotKey
        ) != noErr {
            fputs("Unable to register Control-Option-Command-Period. Use Control-C in Terminal to exit.\n", stderr)
        }

        // 首选项：⌃⌥⌘,
        let prefsID = EventHotKeyID(signature: quitHotKeySignature, id: prefsHotKeyID)
        if RegisterEventHotKey(
            UInt32(kVK_ANSI_Comma), modifiers, prefsID, GetApplicationEventTarget(), 0, &prefsHotKey
        ) != noErr {
            fputs("Unable to register the Control-Option-Command-Comma preferences shortcut.\n", stderr)
        }
    }
}

// 首选项面板：四条滑块（尺寸/速度/屏幕数/增大），拖动即时写回 Settings。
// Settings 被所有渲染器逐帧读取，故尺寸/速度/增大即时可见；屏幕数变化触发窗口重建。
@MainActor
private final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let settings: Settings
    private let sizeValueLabel = NSTextField(labelWithString: "")
    private let speedValueLabel = NSTextField(labelWithString: "")
    private let growthValueLabel = NSTextField(labelWithString: "")
    private let screensValueLabel = NSTextField(labelWithString: "")

    init(settings: Settings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "黑洞设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let window else { return }
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // 屏幕总数（用于把“所有屏幕”映射到滑块最大值）
        let screenCount = max(1, NSScreen.screens.count)

        stack.addArrangedSubview(makeRow(
            title: "尺寸", min: 0, max: 10,
            value: Double(settings.sizeScale), valueLabel: sizeValueLabel,
            format: { String(format: "%.1f", $0) },
            action: #selector(sizeChanged(_:))))
        stack.addArrangedSubview(makeRow(
            title: "漂移速度", min: 0, max: 10,
            value: Double(settings.speedScale), valueLabel: speedValueLabel,
            format: { String(format: "%.1f", $0) },
            action: #selector(speedChanged(_:))))
        stack.addArrangedSubview(makeRow(
            title: "吸附增大", min: 0, max: 10,
            value: Double(settings.growthScale), valueLabel: growthValueLabel,
            format: { $0 < 0.05 ? "关闭" : String(format: "%.1f", $0) },
            action: #selector(growthChanged(_:))))
        // 屏幕数：1..N，其中 N 表示“所有屏幕”
        stack.addArrangedSubview(makeRow(
            title: "屏幕数量", min: 1, max: Double(screenCount),
            value: Double(settings.screenLimit ?? screenCount), valueLabel: screensValueLabel,
            format: { v in
                let n = Int(v.rounded())
                return n >= screenCount ? "全部" : "\(n)"
            },
            action: #selector(screensChangedSlider(_:))))

        let hint = NSTextField(wrappingLabelWithString:
            "拖动即时生效并自动保存。⌃⌥⌘, 打开本面板，⌃⌥⌘. 退出黑洞。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        window.contentView = content
    }

    // 一行：标题 + 滑块 + 数值标签
    private func makeRow(
        title: String, min: Double, max: Double, value: Double,
        valueLabel: NSTextField, format: @escaping (Double) -> String, action: Selector
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        valueLabel.stringValue = format(value)
        valueLabel.alignment = .right
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        // 用关联的 formatter 更新标签（存到 slider 的 identifier 太脏，改用闭包表）
        formatters[ObjectIdentifier(slider)] = (valueLabel, format)

        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    // 每个滑块对应的（数值标签, 格式化闭包）
    private var formatters: [ObjectIdentifier: (NSTextField, (Double) -> String)] = [:]

    private func updateLabel(for slider: NSSlider) {
        if let (label, format) = formatters[ObjectIdentifier(slider)] {
            label.stringValue = format(slider.doubleValue)
        }
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        settings.sizeScale = Float(sender.doubleValue)
        updateLabel(for: sender)
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        settings.speedScale = Float(sender.doubleValue)
        updateLabel(for: sender)
    }

    @objc private func growthChanged(_ sender: NSSlider) {
        settings.growthScale = Float(sender.doubleValue)
        updateLabel(for: sender)
    }

    @objc private func screensChangedSlider(_ sender: NSSlider) {
        let n = Int(sender.doubleValue.rounded())
        let total = max(1, NSScreen.screens.count)
        // 选到最大值视为“全部”（nil），否则限制为前 n 块
        settings.screenLimit = (n >= total) ? nil : n
        updateLabel(for: sender)
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.preferencesDidClose()
    }
}

@main
@MainActor
private struct BlackHoleOverlayApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
