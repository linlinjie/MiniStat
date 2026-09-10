import Foundation
import CoreGraphics

enum ScreenshotTool: Int, CaseIterable {
    case arrow, rectangle, text, redact
    var title: String {
        switch self {
        case .arrow: return "箭头"
        case .rectangle: return "方框"
        case .text: return "文字"
        case .redact: return "实色遮挡"
        }
    }
}

struct ScreenshotMark {
    let tool: ScreenshotTool
    let start: CGPoint
    let end: CGPoint
    var text = ""
    var rect: CGRect { ScreenshotGeometry.rect(from: start, to: end) }
}

enum ScreenshotGeometry {
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    // AppKit points have a bottom-left origin; CGImage crop pixels use top-left.
    static func pixelCrop(selection: CGRect, viewSize: CGSize, pixels: CGSize) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0, pixels.width > 0, pixels.height > 0 else { return nil }
        let area = selection.standardized.intersection(CGRect(origin: .zero, size: viewSize))
        guard !area.isNull, area.width >= 2, area.height >= 2 else { return nil }
        let sx = pixels.width / viewSize.width, sy = pixels.height / viewSize.height
        return CGRect(x: area.minX * sx, y: (viewSize.height - area.maxY) * sy,
                      width: area.width * sx, height: area.height * sy).integral
            .intersection(CGRect(origin: .zero, size: pixels))
    }

    static func fit(image: CGSize, into bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func imagePoint(_ point: CGPoint, in rect: CGRect, pixels: CGSize) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width * pixels.width,
                       y: (point.y - rect.minY) / rect.height * pixels.height)
    }
}
