import Cocoa
import Carbon
import CoreMedia
import CoreVideo
import MetalKit
import QuartzCore
import ScreenCaptureKit

private let quitHotKeySignature: OSType = 0x42484F4C
private let quitHotKeyID: UInt32 = 1

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
    guard status == noErr, identifier.signature == quitHotKeySignature, identifier.id == quitHotKeyID else {
        return OSStatus(eventNotHandledErr)
    }
    NSApp.terminate(nil)
    return noErr
}

private struct RenderUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var radius: Float
    var screenResolution: SIMD2<Float>
    var seed: SIMD2<Float>
    var driftSpeed: Float
}

// 把用户友好的 0-10 刻度线性映射到物理值：scale 5 对应默认观感。
// 缺省或非法输入时返回 scale 5 对应的默认值。
private func scaledOption(
    from arguments: [String],
    key: String,
    lo: Float,
    hi: Float
) -> Float {
    func mapScale(_ scale: Float) -> Float {
        let clamped = min(max(scale, 0), 10)
        return lo + (hi - lo) * (clamped / 10)
    }
    for (index, argument) in arguments.enumerated()
    where argument == key && index + 1 < arguments.count {
        if let scale = Float(arguments[index + 1]) {
            return mapScale(scale)
        }
    }
    return mapScale(5)
}

// 黑洞尺寸：--size [0-10]，映射到阴影半径占屏幕高度的比例。
// 采用分段线性，锚定三点：0→minValue、5→midValue、10→maxValue，
// 让刻度 5 稳定保持默认观感，同时把上半段拉到更大的上限。
// 数值越大，透镜场半径越大，GPU 采样开销越高。
private enum BlackHoleSize {
    static let minValue: Float = 0.02
    static let midValue: Float = 0.055   // 刻度 5，历史默认观感
    static let maxValue: Float = 0.16    // 刻度 10，约屏高的一半

    static func parse(from arguments: [String]) -> Float {
        for (index, argument) in arguments.enumerated()
        where argument == "--size" && index + 1 < arguments.count {
            if let scale = Float(arguments[index + 1]) {
                return mapScale(scale)
            }
        }
        return mapScale(5)
    }

    private static func mapScale(_ scale: Float) -> Float {
        let clamped = min(max(scale, 0), 10)
        if clamped <= 5 {
            return minValue + (midValue - minValue) * (clamped / 5)
        }
        return midValue + (maxValue - midValue) * ((clamped - 5) / 5)
    }
}

// 漂移速度：--speed [0-10]，映射到速度倍率 0-2.0（5→1.0），仅影响漫游，不影响吸积盘转速。
private enum DriftSpeed {
    static func parse(from arguments: [String]) -> Float {
        scaledOption(from: arguments, key: "--speed", lo: 0.0, hi: 2.0)
    }
}

// 渲染的屏幕数量：--screens N，限制在前 N 块显示器上渲染黑洞。
// 至少 1 块，缺省或非法时返回 nil，表示所有屏幕。
private enum ScreenCount {
    static func parse(from arguments: [String]) -> Int? {
        for (index, argument) in arguments.enumerated()
        where argument == "--screens" && index + 1 < arguments.count {
            if let value = Int(arguments[index + 1]) {
                return max(value, 1)
            }
        }
        return nil
    }
}

// 吸附增大速率：--growth [0-10]，控制黑洞随时间“吞噬”桌面而膨胀的快慢。
// 默认 0（关闭，尺寸恒定）；数值越大，半径逼近上限越快。
private enum GrowthRate {
    static func parse(from arguments: [String]) -> Float {
        for (index, argument) in arguments.enumerated()
        where argument == "--growth" && index + 1 < arguments.count {
            if let value = Float(arguments[index + 1]) {
                // 映射到指数增长速率（1/秒）。时间常数 τ = 1/rate：
                // 10→rate 0.05（τ≈20 秒），逼近上限约需 1 分钟；0→关闭。
                return min(max(value, 0), 10) / 10 * 0.05
            }
        }
        return 0
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
    private let frameQueue = DispatchQueue(label: "blackhole.screen-capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var stream: SCStream?
    private var generation: UInt64 = 0

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
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
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
            return stream
        }
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
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
    private let shadowRadius: Float
    private let driftSpeed: Float
    // 吸附增大：growthRate 为 [0,1] 速率（0 关闭）；黑洞半径随时间从初始值
    // 渐近逼近上限，模拟持续吞噬桌面而膨胀。上限同时兜住 GPU 采样开销。
    private let growthRate: Float
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

    init(view: MTKView, resources: RenderResources, captureSource: ScreenCaptureSource, shadowRadius: Float, driftSpeed: Float, growthRate: Float) throws {
        self.shadowRadius = shadowRadius
        self.driftSpeed = driftSpeed
        self.growthRate = growthRate
        self.currentRadius = shadowRadius
        // 增大上限对齐到 --size 的最大值：吸附能长到的最大体积，
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

        // 吸附增大：按帧间 dt 累积（与帧率无关），半径以指数方式渐近逼近上限。
        // growthRate 为 0 时保持初始半径不变。
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastGrowthTime, 0), 0.1))
        lastGrowthTime = now
        if growthRate > 0 && currentRadius < maxRadius {
            currentRadius += (maxRadius - currentRadius) * growthRate * dt
            currentRadius = min(currentRadius, maxRadius)
        }

        // 静止降帧：按全局输入空闲时间判断。距上次鼠标/键盘操作超过 idleThreshold
        // 秒就降到 idleFPS 省电，一有输入立刻回到 activeFPS。吸附增大过程中黑洞
        // 体积仍在变，视为活跃以保持膨胀平滑。
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
        let growing = growthRate > 0 && currentRadius < maxRadius
        let targetFPS = (growing || idleSeconds < BlackHoleRenderer.idleThreshold)
            ? BlackHoleRenderer.activeFPS
            : BlackHoleRenderer.idleFPS
        if targetFPS != currentFPS {
            currentFPS = targetFPS
            view.preferredFramesPerSecond = targetFPS
        }

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

    init(blackHoleFrame frame: CGRect, resources: RenderResources, captureSource: ScreenCaptureSource, shadowRadius: Float, driftSpeed: Float, growthRate: Float) throws {
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

        let renderer = try BlackHoleRenderer(view: self, resources: resources, captureSource: captureSource, shadowRadius: shadowRadius, driftSpeed: driftSpeed, growthRate: growthRate)
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
    private let size = BlackHoleSize.parse(from: CommandLine.arguments)
    private let driftSpeed = DriftSpeed.parse(from: CommandLine.arguments)
    private let screenLimit = ScreenCount.parse(from: CommandLine.arguments)
    private let growthRate = GrowthRate.parse(from: CommandLine.arguments)
    // 共享的 Metal 设备与编译好的着色器 library，启动时创建一次，供所有屏幕复用
    private var renderResources: RenderResources?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerGlobalQuitHotKey()
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
        if let quitHotKeyHandler { RemoveEventHandler(quitHotKeyHandler) }
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

        // 限制渲染的屏幕数量：默认所有屏幕，--screens N 只取前 N 块
        let screens = screenLimit.map { Array(NSScreen.screens.prefix($0)) } ?? NSScreen.screens
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
                    shadowRadius: size,
                    driftSpeed: driftSpeed,
                    growthRate: growthRate
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

    private func registerGlobalQuitHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), handleGlobalHotKey, 1, &eventType, nil, &quitHotKeyHandler
        )
        guard handlerStatus == noErr else {
            fputs("Unable to install the global quit shortcut. Use Control-C in Terminal to exit.\n", stderr)
            return
        }
        let identifier = EventHotKeyID(signature: quitHotKeySignature, id: quitHotKeyID)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Period), modifiers, identifier, GetApplicationEventTarget(), 0, &quitHotKey
        )
        if hotKeyStatus != noErr {
            fputs("Unable to register Control-Option-Command-Period. Use Control-C in Terminal to exit.\n", stderr)
        }
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
