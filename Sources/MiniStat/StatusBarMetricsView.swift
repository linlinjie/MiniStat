import AppKit

final class StatusBarMetricsView: NSView {
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
    private static let networkValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let networkLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let centeredParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        return paragraph.copy() as! NSParagraphStyle
    }()

    private(set) var snapshot = MetricSnapshot.empty
    var quotaCells: [(String, String)] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    private(set) var visibleModules = AppPreferences.defaults.visibleModules
    var menuHighlighted = false {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(snapshot: MetricSnapshot, visibleModules: Set<MetricModule>) {
        let layoutChanged = self.visibleModules != visibleModules
        self.snapshot = snapshot
        self.visibleModules = visibleModules
        if layoutChanged {
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }

    var requiredWidth: CGFloat {
        guard !visibleModules.isEmpty || !quotaCells.isEmpty else { return 26 }
        return MetricModule.allCases
            .filter(visibleModules.contains)
            .reduce(CGFloat(quotaCells.count * 64)) { $0 + width(for: $1) }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: requiredWidth, height: NSStatusBar.system.thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !visibleModules.isEmpty || !quotaCells.isEmpty else {
            drawFallbackIcon()
            return
        }

        let modules = MetricModule.allCases.filter(visibleModules.contains)
        var x: CGFloat = 0
        for (index, module) in modules.enumerated() {
            let moduleWidth = width(for: module)
            let rect = NSRect(x: x, y: 0, width: moduleWidth, height: bounds.height)
            draw(module: module, in: rect)

            if index < modules.count - 1 {
                let separator = NSRect(x: rect.maxX - 0.5, y: 4, width: 1, height: max(8, bounds.height - 8))
                textColor.withAlphaComponent(0.25).setFill()
                separator.fill()
            }
            x += moduleWidth
        }
        for (name, value) in quotaCells {
            drawCentered(value, in: NSRect(x: x + 3, y: floor(bounds.midY) - 0.5, width: 58, height: bounds.height / 2 + 1), font: Self.valueFont)
            drawCentered(name.uppercased(), in: NSRect(x: x + 3, y: 0.5, width: 58, height: floor(bounds.midY)), font: Self.labelFont)
            x += 64
        }
    }

    private var textColor: NSColor {
        menuHighlighted ? .selectedMenuItemTextColor : .labelColor
    }

    private func width(for module: MetricModule) -> CGFloat {
        switch module {
        case .cpu, .memory, .disk: return 46
        case .temperature: return 54
        case .network: return 90
        }
    }

    private func draw(module: MetricModule, in rect: NSRect) {
        let topText: String
        let bottomText: String
        switch module {
        case .cpu:
            topText = MetricFormatter.percent(snapshot.cpuPercent)
            bottomText = "CPU"
        case .memory:
            topText = MetricFormatter.percent(snapshot.memoryPercent)
            bottomText = "MEM"
        case .disk:
            topText = MetricFormatter.percent(snapshot.diskPercent)
            bottomText = "SSD"
        case .temperature:
            topText = MetricFormatter.temperature(snapshot.temperatureCelsius)
            bottomText = "TEMP"
        case .network:
            topText = "↑ \(MetricFormatter.rate(snapshot.uploadBytesPerSecond))"
            bottomText = "↓ \(MetricFormatter.rate(snapshot.downloadBytesPerSecond))"
        }

        let midY = floor(rect.midY)
        drawCentered(
            topText,
            in: NSRect(x: rect.minX + 3, y: midY - 0.5, width: rect.width - 7, height: rect.maxY - midY + 0.5),
            font: module == .network ? Self.networkValueFont : Self.valueFont
        )
        drawCentered(
            bottomText,
            in: NSRect(x: rect.minX + 3, y: 0.5, width: rect.width - 7, height: midY),
            font: module == .network ? Self.networkLabelFont : Self.labelFont
        )
    }

    private func drawCentered(_ string: String, in rect: NSRect, font: NSFont) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: Self.centeredParagraph
        ]
        (string as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func drawFallbackIcon() {
        guard let baseImage = NSImage(
            systemSymbolName: "gauge.with.dots.needle.33percent",
            accessibilityDescription: "MiniStat"
        ) else {
            drawCentered("●", in: bounds, font: .systemFont(ofSize: 10))
            return
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        let imageSize = image.size
        let target = NSRect(
            x: bounds.midX - imageSize.width / 2,
            y: bounds.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        image.draw(in: target)
    }
}
