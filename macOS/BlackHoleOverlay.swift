import Cocoa
import Carbon

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

private func blackHolePosition(in bounds: CGRect, time: CFTimeInterval, radius: CGFloat) -> CGPoint {
    let xRange = max(0, bounds.width / 2 - radius * 1.8)
    let yRange = max(0, bounds.height / 2 - radius * 1.8)
    let t = CGFloat(time) * 0.09
    return CGPoint(
        x: bounds.midX + sin(t * 0.77 + 0.8) * xRange * 0.72 + sin(t * 1.71) * xRange * 0.14,
        y: bounds.midY + cos(t * 0.64 + 1.6) * yRange * 0.62 + cos(t * 1.43) * yRange * 0.11
    )
}

private final class BlackHoleView: NSView {
    private var timer: Timer?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        let frameTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        frameTimer.tolerance = 0
        RunLoop.main.add(frameTimer, forMode: .common)
        timer = frameTimer
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            timer?.invalidate()
            timer = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        let time = CACurrentMediaTime()
        let radius = max(33, min(bounds.width, bounds.height) * 0.06)
        let hole = blackHolePosition(in: bounds, time: time, radius: radius)
        drawHorizon(context: context, hole: hole, radius: radius, time: time)
    }

    private func drawHorizon(context: CGContext, hole: CGPoint, radius: CGFloat, time: CFTimeInterval) {
        let shadow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                CGColor(red: 0.04, green: 0.05, blue: 0.18, alpha: 0)
            ] as CFArray,
            locations: [0, 0.62, 1]
        )!
        context.drawRadialGradient(shadow, startCenter: hole, startRadius: radius * 0.38, endCenter: hole, endRadius: radius * 1.36, options: [])
        context.setFillColor(CGColor(red: 0, green: 0.002, blue: 0.02, alpha: 1))
        context.fillEllipse(in: CGRect(x: hole.x - radius, y: hole.y - radius, width: radius * 2, height: radius * 2))
        let rimAlpha = 0.13 + sin(CGFloat(time) * 1.8) * 0.035
        context.setStrokeColor(CGColor(red: 0.55, green: 0.62, blue: 1, alpha: rimAlpha))
        context.setLineWidth(max(1, radius * 0.025))
        context.strokeEllipse(in: CGRect(x: hole.x - radius * 1.03, y: hole.y - radius * 1.03, width: radius * 2.06, height: radius * 2.06))
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var quitHotKey: EventHotKeyRef?
    private var quitHotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerGlobalQuitHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        buildWindows()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let quitHotKey { UnregisterEventHotKey(quitHotKey) }
        if let quitHotKeyHandler { RemoveEventHandler(quitHotKeyHandler) }
    }

    @objc private func screensChanged() {
        buildWindows()
    }

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = BlackHoleView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.orderFrontRegardless()
            return window
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
