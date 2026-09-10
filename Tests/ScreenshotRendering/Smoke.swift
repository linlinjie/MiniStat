import AppKit
import Vision

@main
struct ScreenshotRenderingSmoke {
    @MainActor static func main() {
        do { try run() }
        catch {
            fputs("Screenshot rendering/OCR test failed. Vision requires access to the macOS graphics services in a GUI session.\n", stderr)
            exit(1)
        }
    }
    @MainActor private static func run() throws {
        _ = NSApplication.shared
        let status = StatusBarMetricsView(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        status.update(snapshot: .empty, visibleModules: [])
        precondition(status.requiredWidth == 26, "empty status keeps fallback")
        status.quotaColumns = [QuotaReading.statusCells(provider: "Codex", reading: nil)]
        precondition(status.requiredWidth == 96, "one provider occupies one column")
        status.quotaColumns.append(QuotaReading.statusCells(provider: "Cursor", reading: nil))
        precondition(status.requiredWidth == 192, "two providers reduced from 256 to 192 points")
        for label in ["CODEX 5H", "CODEX 30D", "CURSOR M", "OTHER M"] {
            let size = (label + " 100%*" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)])
            precondition(size.width <= 92 && size.height <= 11, "longest quota row fits without clipping")
        }
        if CommandLine.arguments.count > 1 {
            let preview = status.bitmapImageRepForCachingDisplay(in: status.bounds)!
            status.cacheDisplay(in: status.bounds, to: preview)
            try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + ".quota.png"))
        }
        print("Quota layout: fallback, single/two providers and longest row fit passed")
        guard let context = CGContext(data: nil, width: 800, height: 480, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 480))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 400, width: 800, height: 80))
        let base = context.makeImage()!
        let marks = [
            ScreenshotMark(tool: .text, start: CGPoint(x: 35, y: 340), end: .zero, text: "MiniStat Screenshot — Local Only"),
            ScreenshotMark(tool: .rectangle, start: CGPoint(x: 30, y: 230), end: CGPoint(x: 400, y: 315)),
            ScreenshotMark(tool: .arrow, start: CGPoint(x: 560, y: 170), end: CGPoint(x: 410, y: 260)),
            ScreenshotMark(tool: .text, start: CGPoint(x: 45, y: 130), end: .zero, text: "SECRET918273"),
            ScreenshotMark(tool: .redact, start: CGPoint(x: 40, y: 100), end: CGPoint(x: 320, y: 180))
        ]
        let rendered = ScreenshotRenderer.flatten(image: base, marks: marks)!
        precondition(rendered.width == 800 && rendered.height == 480, "pixel dimensions must be preserved")
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let covered = bitmap.colorAt(x: 100, y: 340)!.usingColorSpace(.deviceRGB)!
        precondition(covered.redComponent < 0.01 && covered.greenComponent < 0.01 && covered.blueComponent < 0.01 && covered.alphaComponent > 0.99,
                     "redaction must be opaque black in exported pixels")
        let top = bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        precondition(top.blueComponent > top.redComponent, "image orientation must remain upright")
        let untouched = ScreenshotRenderer.flatten(image: base, marks: [])!
        let originalColor = NSBitmapImageRep(cgImage: untouched).colorAt(x: 100, y: 340)!.usingColorSpace(.deviceRGB)!
        precondition(originalColor.redComponent > 0.99, "undo state must preserve original image")
        let canvas = ScreenshotCanvas(image: base)
        canvas.addText("test", at: CGPoint(x: 5, y: 5))
        precondition(canvas.marks.count == 1)
        canvas.undoMark()
        precondition(canvas.marks.isEmpty)
        let cropRect = ScreenshotGeometry.pixelCrop(selection: CGRect(x: 0, y: 200, width: 100, height: 40),
            viewSize: CGSize(width: 400, height: 240), pixels: CGSize(width: 800, height: 480))!
        let crop = base.cropping(to: cropRect)!
        precondition(crop.width == 200 && crop.height == 80)
        let cropColor = NSBitmapImageRep(cgImage: crop).colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        precondition(cropColor.blueComponent > cropColor.redComponent, "retina selection must crop the intended top strip")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: rendered, options: [:]).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        precondition(recognized.lowercased().contains("screenshot"), "OCR must recognize visible sample text")
        precondition(!recognized.contains("918273"), "OCR must not recognize covered text")
        if CommandLine.arguments.count > 1 {
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            let editor = ScreenshotEditor(image: rendered)
            let view = editor.window!.contentView!
            view.layoutSubtreeIfNeeded()
            if let preview = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: preview)
                try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + ".editor.png"))
            }
            editor.close()
        }
        print("Screenshot rendering: dimensions, opaque redaction, orientation, undo, Retina crop and redacted-image OCR passed")
    }
}
