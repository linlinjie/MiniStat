import AppKit

enum ScreenshotRenderer {
    static func draw(image: CGImage, marks: [ScreenshotMark], in context: CGContext) {
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let lineWidth = max(3, min(size.width, size.height) / 220)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for mark in marks {
            context.setStrokeColor(NSColor.systemRed.cgColor)
            switch mark.tool {
            case .rectangle:
                context.stroke(mark.rect)
            case .redact:
                // Opaque pixels, not blur: the exported image has no recoverable layer.
                context.setFillColor(NSColor.black.cgColor)
                context.fill(mark.rect.integral)
            case .arrow:
                let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
                let head = max(12, lineWidth * 4)
                context.move(to: mark.start); context.addLine(to: mark.end)
                context.move(to: CGPoint(x: mark.end.x - head * cos(angle - .pi / 6), y: mark.end.y - head * sin(angle - .pi / 6)))
                context.addLine(to: mark.end)
                context.addLine(to: CGPoint(x: mark.end.x - head * cos(angle + .pi / 6), y: mark.end.y - head * sin(angle + .pi / 6)))
                context.strokePath()
            case .text:
                let font = NSFont.systemFont(ofSize: max(18, lineWidth * 6), weight: .semibold)
                (mark.text as NSString).draw(at: mark.start, withAttributes: [.font: font, .foregroundColor: NSColor.systemRed])
            }
        }
    }

    static func flatten(image: CGImage, marks: [ScreenshotMark]) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(image: image, marks: marks, in: context)
        return context.makeImage()
    }
}

final class ScreenshotCanvas: NSView {
    let image: CGImage
    var tool: ScreenshotTool = .arrow { didSet { draft = nil; needsDisplay = true } }
    private(set) var marks: [ScreenshotMark] = []
    var requestText: ((CGPoint) -> Void)?
    var onChange: (() -> Void)?
    private var draft: ScreenshotMark?
    private var pixels: CGSize { CGSize(width: image.width, height: image.height) }
    private var imageRect: CGRect { ScreenshotGeometry.fit(image: pixels, into: bounds.insetBy(dx: 14, dy: 14)) }

    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext, imageRect.width > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: imageRect.minX, y: imageRect.minY)
        context.scaleBy(x: imageRect.width / pixels.width, y: imageRect.height / pixels.height)
        context.clip(to: CGRect(origin: .zero, size: pixels))
        ScreenshotRenderer.draw(image: image, marks: marks + (draft.map { [$0] } ?? []), in: context)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = ScreenshotGeometry.imagePoint(convert(event.locationInWindow, from: nil), in: imageRect, pixels: pixels) else { return }
        if tool == .text { requestText?(point); return }
        draft = ScreenshotMark(tool: tool, start: point, end: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let old = draft else { return }
        let p = convert(event.locationInWindow, from: nil)
        let bounded = CGPoint(x: max(imageRect.minX, min(imageRect.maxX - 0.01, p.x)),
                              y: max(imageRect.minY, min(imageRect.maxY - 0.01, p.y)))
        guard let end = ScreenshotGeometry.imagePoint(bounded, in: imageRect, pixels: pixels) else { return }
        draft = ScreenshotMark(tool: old.tool, start: old.start, end: end)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if let draft, hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) > 3 {
            marks.append(draft); onChange?()
        }
        draft = nil; needsDisplay = true
    }

    func addText(_ text: String, at point: CGPoint) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        marks.append(ScreenshotMark(tool: .text, start: point, end: point, text: text))
        needsDisplay = true; onChange?()
    }
    func undoMark() { if !marks.isEmpty { marks.removeLast() }; draft = nil; needsDisplay = true; onChange?() }
    func renderedImage() -> CGImage? { ScreenshotRenderer.flatten(image: image, marks: marks) }
}
