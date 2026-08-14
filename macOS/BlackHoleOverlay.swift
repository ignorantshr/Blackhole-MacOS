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
        }
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

private final class BlackHoleRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let captureSource: ScreenCaptureSource
    private let textureCache: CVMetalTextureCache
    private let startTime = CACurrentMediaTime()
    private let shadowRadius: Float
    private let driftSpeed: Float
    // 吸附增大：growthRate 为 [0,1] 速率（0 关闭）；黑洞半径随时间从初始值
    // 渐近逼近上限，模拟持续吞噬桌面而膨胀。上限同时兜住 GPU 采样开销。
    private let growthRate: Float
    private let maxRadius: Float
    private var currentRadius: Float
    private var lastGrowthTime = CACurrentMediaTime()
    // 每个渲染器（每块屏幕）一个随机种子：seed.x 为随机相位，seed.y 为随机时间偏移，
    // 令每块屏幕的漂移轨迹互不相同，且每次启动都不一样。
    private let seed = SIMD2<Float>(
        Float.random(in: 0 ..< (2 * Float.pi)),
        Float.random(in: 0 ..< 1000)
    )

    init(view: MTKView, captureSource: ScreenCaptureSource, shadowRadius: Float, driftSpeed: Float, growthRate: Float) throws {
        self.shadowRadius = shadowRadius
        self.driftSpeed = driftSpeed
        self.growthRate = growthRate
        self.currentRadius = shadowRadius
        // 增大上限对齐到 --size 的最大值：吸附能长到的最大体积，
        // 恰好等于手动能设的最大尺寸，概念统一，也兜住重采样 GPU 开销。
        self.maxRadius = BlackHoleSize.maxValue
        guard let device = view.device, let commandQueue = device.makeCommandQueue() else {
            throw RendererError.noMetalDevice
        }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache
        else {
            throw RendererError.noTextureCache
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let shaderURL = executableURL.deletingLastPathComponent().appendingPathComponent("BlackHoleShaders.metal")
        guard let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            throw RendererError.missingShaderSource(shaderURL.path)
        }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
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

    init(blackHoleFrame frame: CGRect, captureSource: ScreenCaptureSource, shadowRadius: Float, driftSpeed: Float, growthRate: Float) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noMetalDevice
        }
        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        wantsLayer = true
        layer?.isOpaque = false

        let renderer = try BlackHoleRenderer(view: self, captureSource: captureSource, shadowRadius: shadowRadius, driftSpeed: driftSpeed, growthRate: growthRate)
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
