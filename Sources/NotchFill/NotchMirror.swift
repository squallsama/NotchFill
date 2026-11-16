import AppKit
import CoreMedia
import ScreenCaptureKit

/// "Rear-view mirror": when the pointer goes behind the notch, show what is behind it
/// (pointer included) in a small panel just below the notch. The panel ignores the mouse,
/// so clicks go to the app at the real pointer position, behind the notch.
///
/// Uses ScreenCaptureKit on the notch rect only, so it needs Screen Recording permission.
final class NotchMirror: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called when the mirror cannot run (no permission, capture failed). The mirror is
    /// stopped by then.
    var onError: ((String) -> Void)?

    private(set) var isRunning = false
    /// On, but no screen has a notch right now (lid closed with an external display).
    /// Starts again when the notched screen comes back.
    private(set) var isWaitingForScreen = false
    /// Running or waiting: what the menu shows as on.
    var isOn: Bool { isRunning || isWaitingForScreen }
    private var target: NotchScreen?
    private var panel: NSPanel?
    private let imageLayer = CALayer()
    private var stream: SCStream?
    private var timer: Timer?
    private var lastInside = Date.distantPast
    private var generation = 0
    private var lastSurface: IOSurface?

    /// For diagnostics: is the panel on screen, and how many frames are there.
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// For diagnostics: write the last captured frame (what the mirror shows) as PNG.
    func writeSnapshot(to path: String) -> Bool {
        guard let surface = lastSurface else { return false }
        let image = CIImage(ioSurface: surface)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data)
    }
    private let queue = DispatchQueue(label: "dev.notchfill.mirror", qos: .userInteractive)

    /// Magnification of the mirror image.
    private let zoom: CGFloat = 2
    /// Extra points captured on each side of the notch, so the image has context.
    private let sideMargin: CGFloat = 16
    /// Gap between the notch and the mirror.
    private let gap: CGFloat = 6

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// - Parameter waitForScreen: with no notched screen now, wait for one instead of
    ///   reporting an error (used at app launch and when screens change).
    func start(waitForScreen: Bool = false) {
        guard !isRunning else { return }
        isWaitingForScreen = false
        guard let t = NotchGeometry.notchedScreen() else {
            if waitForScreen {
                isWaitingForScreen = true
            } else {
                onError?("Mirror: no screen with a notch.")
            }
            return
        }
        if !Self.hasPermission {
            CGRequestScreenCaptureAccess()
            onError?("Mirror needs Screen Recording permission. Allow NotchFill, then turn the mirror on again.")
            return
        }
        isRunning = true
        target = t
        makePanel(for: t)
        startStream(for: t)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isWaitingForScreen = false
        stopCapture()
    }

    private func stopCapture() {
        generation += 1
        isRunning = false
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let s = stream
        stream = nil
        s?.stopCapture { _ in }
    }

    /// Stop, then tell the app. Without the stop the menu would still show the mirror as
    /// on, and the panel would show the last frame (or nothing) at every hover.
    private func fail(_ message: String) {
        stop()
        onError?(message)
    }

    func screensChanged() {
        guard isOn else { return }
        stopCapture()
        start(waitForScreen: true)
    }

    // MARK: Pointer tracking

    private func tick() {
        guard let t = target, let panel else { return }
        let m = NSEvent.mouseLocation
        let n = t.notchRect
        let inside = m.x >= n.minX - 1 && m.x <= n.maxX + 1 && m.y >= n.minY - 1 && m.y <= t.fullFrame.maxY + 1
        if inside {
            lastInside = Date()
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
        } else if panel.isVisible, Date().timeIntervalSince(lastInside) > 0.2 {
            panel.orderOut(nil)
        }
    }

    // MARK: Panel

    private func makePanel(for t: NotchScreen) {
        let src = t.notchRectDisplayLocal(expandedBy: sideMargin)
        let size = CGSize(width: src.width * zoom, height: src.height * zoom)
        let frame = CGRect(x: t.notchRect.midX - size.width / 2,
                           y: t.notchRect.minY - gap - size.height,
                           width: size.width, height: size.height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Above full screen games, including games that capture the display.
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none

        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        let root = view.layer!
        root.backgroundColor = NSColor.black.cgColor
        root.cornerRadius = 10
        root.cornerCurve = .continuous
        root.masksToBounds = true
        root.borderWidth = 1
        root.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        imageLayer.frame = root.bounds
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        root.addSublayer(imageLayer)
        p.contentView = view
        panel = p
    }

    // MARK: Capture

    private func startStream(for t: NotchScreen) {
        let gen = generation
        let margin = sideMargin
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard gen == self.generation else { return }
                guard let display = content.displays.first(where: { $0.displayID == t.displayID }) else {
                    self.fail("Mirror: cannot find the display to capture.")
                    return
                }
                let me = content.applications.filter { $0.processID == getpid() }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                let src = t.notchRectDisplayLocal(expandedBy: margin)
                let scale = t.screen.backingScaleFactor
                cfg.sourceRect = src
                cfg.width = Int(src.width * scale)
                cfg.height = Int(src.height * scale)
                cfg.showsCursor = true
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                cfg.queueDepth = 3
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.capturesAudio = false

                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                guard gen == self.generation else {
                    try? await s.stopCapture()
                    return
                }
                self.stream = s
            } catch {
                // Ignore errors of a capture that was stopped in the meantime.
                guard gen == self.generation else { return }
                self.fail("Mirror: \(error.localizedDescription)")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [imageLayer] in
            self.lastSurface = surface
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.fail("Mirror stopped: \(error.localizedDescription)")
        }
    }
}
