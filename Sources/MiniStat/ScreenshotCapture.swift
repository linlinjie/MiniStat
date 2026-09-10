import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

// Compatible with the installed macOS 13 SDK: receive one complete frame,
// stop the short-lived stream, then return the image. No recording is retained.
private final class OneFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var timeout: DispatchWorkItem?
    private let lock = NSLock()
    private var finished = false
    private let frameQueue = DispatchQueue(label: "local.ministat.screenshot.frame", qos: .userInitiated)

    static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let capture = OneFrameCapture()
            capture.completion = { continuation.resume(with: $0) }
            capture.start(filter: filter, configuration: configuration)
        }
    }

    private func start(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        // The timeout retains the capture until a result or deadline is reached.
        let deadline = DispatchWorkItem { [self] in
            finish(.failure(NSError(domain: "MiniStatCaptureTimeout", code: 1)))
        }
        timeout = deadline
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
            stream.startCapture { [self] error in
                if let error { finish(.failure(error)) }
            }
        } catch { finish(.failure(error)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(.failure(error)) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock(); let alreadyFinished = finished; lock.unlock()
        guard !alreadyFinished, type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return }
        finish(.success(cgImage))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = completion; completion = nil
        let activeStream = stream; stream = nil
        timeout?.cancel(); timeout = nil
        lock.unlock()
        if let activeStream {
            activeStream.stopCapture { _ in callback?(result) }
        } else { callback?(result) }
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ScreenshotSelectionView: NSView {
    let image: CGImage
    var complete: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero
    init(image: CGImage, frame: CGRect) { self.image = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill(); shade.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: selection); outline.lineWidth = 1; outline.stroke()
        }
        let hint = "拖动框选 · Esc 取消 · 当前屏幕内选择"
        (hint as NSString).draw(at: NSPoint(x: 24, y: bounds.height - 62), withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ])
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = ScreenshotGeometry.rect(from: start, to: p).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 2, selection.height >= 2 else { start = nil; return }
        complete?(selection)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { complete?(nil) } else { super.keyDown(with: event) }
    }
}

@MainActor
final class ScreenshotCapture {
    private var overlays: [NSPanel] = []
    private var editor: ScreenshotEditor?
    private var busy = false

    func begin() {
        guard !busy, overlays.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "允许 MiniStat 截取屏幕"
            alert.informativeText = "仅在你点击截图时读取屏幕。图片和 OCR 在本机处理，不自动保存或上传。首次使用需在系统设置中允许屏幕录制；授权后可能需要重启 MiniStat。"
            alert.addButton(withTitle: "请求系统授权"); alert.addButton(withTitle: "取消")
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { _ = CGRequestScreenCaptureAccess() }
            return
        }
        editor?.close(); editor = nil
        busy = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var captures: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
                    configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
                    configuration.showsCursor = false
                    configuration.queueDepth = 1
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let image = try await OneFrameCapture.capture(filter: filter, configuration: configuration)
                    captures.append((screen, image))
                }
                guard !captures.isEmpty else { throw NSError(domain: "MiniStatCapture", code: 1) }
                self.busy = false
                self.showSelections(captures)
            } catch {
                self.busy = false
                self.showMessage("截图失败", "请检查系统设置中的屏幕录制权限。若刚授权，请退出并重新打开 MiniStat 后重试。")
            }
        }
    }

    private func showSelections(_ captures: [(NSScreen, CGImage)]) {
        for (screen, image) in captures {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            let view = ScreenshotSelectionView(image: image, frame: CGRect(origin: .zero, size: screen.frame.size))
            panel.contentView = view
            view.complete = { [weak self, weak view] selection in
                guard let self else { return }
                var cropped: CGImage?
                if let selection, let view,
                   let rect = ScreenshotGeometry.pixelCrop(selection: selection, viewSize: view.bounds.size,
                      pixels: CGSize(width: image.width, height: image.height)) { cropped = image.cropping(to: rect) }
                self.overlays.forEach { $0.orderOut(nil); $0.close() }
                self.overlays.removeAll()
                if let cropped { self.showEditor(cropped) }
            }
            overlays.append(panel)
            panel.orderFrontRegardless()
            if screen.frame.contains(NSEvent.mouseLocation) { panel.makeKey(); panel.makeFirstResponder(view) }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showEditor(_ image: CGImage) {
        editor?.close()
        let controller = ScreenshotEditor(image: image)
        editor = controller
        controller.onClose = { [weak self, weak controller] in
            if self?.editor === controller { self?.editor = nil }
        }
        controller.present()
    }

    private func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        NSApplication.shared.activate(ignoringOtherApps: true); alert.runModal()
    }
}
