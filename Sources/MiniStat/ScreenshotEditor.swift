import AppKit
import Vision
import UniformTypeIdentifiers

private final class ScreenshotEditorBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

@MainActor
final class ScreenshotEditor: NSWindowController, NSWindowDelegate {
    private let canvas: ScreenshotCanvas
    private let undoButton = NSButton(title: "撤销", target: nil, action: nil)
    private let ocrButton = NSButton(title: "提取文字", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?

    init(image: CGImage) {
        canvas = ScreenshotCanvas(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MiniStat · 截图标注"
        window.minSize = NSSize(width: 820, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = ScreenshotEditorBackground()
        window.contentView = root
        let tools = NSSegmentedControl(labels: ScreenshotTool.allCases.map(\.title), trackingMode: .selectOne,
                                       target: self, action: #selector(changeTool(_:)))
        tools.selectedSegment = 0
        undoButton.target = self; undoButton.action = #selector(undo)
        undoButton.keyEquivalent = "z"; undoButton.isEnabled = false
        ocrButton.target = self; ocrButton.action = #selector(recognizeText)
        let copy = NSButton(title: "复制", target: self, action: #selector(copyImage))
        copy.keyEquivalent = "c"
        let save = NSButton(title: "保存 PNG", target: self, action: #selector(saveImage))
        save.keyEquivalent = "s"
        let pin = NSButton(checkboxWithTitle: "置顶", target: self, action: #selector(togglePin(_:)))
        let row = NSStackView(views: [tools, undoButton, ocrButton, pin, copy, save])
        row.orientation = .horizontal; row.spacing = 10
        statusLabel.stringValue = "\(image.width) × \(image.height) px · 拖动添加标注；文字工具点击图片输入；遮挡为纯黑实色"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        for view in [row, canvas, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            row.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            canvas.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 10),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        canvas.onChange = { [weak self] in self?.undoButton.isEnabled = !(self?.canvas.marks.isEmpty ?? true) }
        canvas.requestText = { [weak self] point in self?.askForText(at: point) }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    @objc private func changeTool(_ sender: NSSegmentedControl) {
        canvas.tool = ScreenshotTool(rawValue: sender.selectedSegment) ?? .arrow
    }
    @objc private func undo() { canvas.undoMark() }
    @objc private func togglePin(_ sender: NSButton) { window?.level = sender.state == .on ? .floating : .normal }

    private func askForText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "添加文字"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        field.placeholderString = "输入标注内容"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { canvas.addText(field.stringValue, at: point) }
    }

    @objc private func copyImage() {
        guard let image = canvas.renderedImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            showError("无法生成截图，请重试。"); return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setData(png, forType: .png) { statusLabel.stringValue = "已复制标注后的截图，可直接粘贴。" }
        else { showError("剪贴板写入失败。") }
    }

    @objc private func saveImage() {
        guard let image = canvas.renderedImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            showError("无法生成截图，请重试。"); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "MiniStat-\(formatter.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url, options: .atomic); statusLabel.stringValue = "已保存：\(url.lastPathComponent)" }
        catch { showError("保存失败，请检查目录权限或磁盘空间。") }
    }

    @objc private func recognizeText() {
        // OCR uses the flattened, redacted image rather than the original.
        guard ocrButton.isEnabled, let image = canvas.renderedImage() else { return }
        ocrButton.isEnabled = false; statusLabel.stringValue = "正在本机识别文字，不上传图片…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                DispatchQueue.main.async { [weak self] in self?.finishOCR(text: text) }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.ocrButton.isEnabled = true; self?.showError("文字识别失败，请稍后重试。")
                }
            }
        }
    }

    private func finishOCR(text: String) {
        ocrButton.isEnabled = true
        guard window?.isVisible == true else { return }
        statusLabel.stringValue = text.isEmpty ? "未识别到文字。" : "文字识别完成。"
        guard !text.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "识别结果（本机处理）"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        let view = NSTextView(frame: scroll.bounds)
        view.string = text; view.isEditable = false
        view.font = .systemFont(ofSize: 14)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        scroll.hasVerticalScroller = true; scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: "复制文字"); alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message; alert.runModal()
    }
}
