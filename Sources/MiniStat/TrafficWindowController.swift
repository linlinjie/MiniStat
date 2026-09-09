import AppKit

@MainActor
final class TrafficWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String {
        case application
        case downloadRate
        case uploadRate
        case downloaded
        case uploaded
    }

    private let monitor = ProcessTrafficMonitor()
    private let tableView = NSTableView()
    private let sortControl = NSSegmentedControl(
        labels: ["当前速度", "累计流量"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private var allRows: [ApplicationTraffic] = []
    private var visibleRows: [ApplicationTraffic] = []
    private var isMonitoring = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "应用流量 Top 10"
        window.minSize = NSSize(width: 660, height: 320)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard !isMonitoring else { return }

        isMonitoring = true
        allRows = []
        visibleRows = []
        tableView.reloadData()
        statusLabel.stringValue = "正在采样进程流量，约 2 秒后显示…"

        monitor.start(
            onUpdate: { [weak self] rows in
                DispatchQueue.main.async {
                    self?.apply(rows)
                }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = "无法读取应用流量：\(message)"
                }
            }
        )
    }

    func windowWillClose(_ notification: Notification) {
        monitor.stop()
        isMonitoring = false
        statusLabel.stringValue = "已停止采样"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue),
              visibleRows.indices.contains(row) else { return nil }

        let traffic = visibleRows[row]
        let value: String
        switch column {
        case .application:
            value = "\(row + 1).  \(traffic.name)"
        case .downloadRate:
            value = MetricFormatter.rate(traffic.downloadBytesPerSecond)
        case .uploadRate:
            value = MetricFormatter.rate(traffic.uploadBytesPerSecond)
        case .downloaded:
            value = MetricFormatter.bytes(traffic.downloadedBytes)
        case .uploaded:
            value = MetricFormatter.bytes(traffic.uploadedBytes)
        }

        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = column == .application ? traffic.name : value
        if column == .application {
            field.font = .systemFont(ofSize: 12.5, weight: .medium)
            field.alignment = .left
        } else {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.alignment = .right
        }
        return field
    }

    @objc private func changeSortMode() {
        updateVisibleRows()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "按应用统计 · Top 10")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        sortControl.selectedSegment = 0
        sortControl.target = self
        sortControl.action = #selector(changeSortMode)

        let topBar = NSStackView(views: [heading, NSView(), sortControl])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 10

        addColumn(.application, title: "应用 / 进程", width: 220, minWidth: 150)
        addColumn(.downloadRate, title: "当前下载", width: 112, minWidth: 95)
        addColumn(.uploadRate, title: "当前上传", width: 112, minWidth: 95)
        addColumn(.downloaded, title: "累计下载", width: 105, minWidth: 90)
        addColumn(.uploaded, title: "累计上传", width: 105, minWidth: 90)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 25
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = false

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.lineBreakMode = .byTruncatingTail

        for view in [topBar, scrollView, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat, minWidth: CGFloat) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = minWidth
        tableView.addTableColumn(tableColumn)
    }

    private func apply(_ rows: [ApplicationTraffic]) {
        guard isMonitoring else { return }
        allRows = rows
        updateVisibleRows()

        if visibleRows.isEmpty {
            statusLabel.stringValue = "暂未检测到应用流量 · 每秒更新 · 关闭窗口后停止采样"
        } else {
            statusLabel.stringValue = "累计值从本次打开列表开始计算 · 每秒更新 · 关闭窗口后停止采样"
        }
    }

    private func updateVisibleRows() {
        let mode: TrafficSortMode = sortControl.selectedSegment == 1 ? .totalBytes : .currentRate
        let sorted = allRows.sorted { lhs, rhs in
            let lhsValue: Double
            let rhsValue: Double
            switch mode {
            case .currentRate:
                lhsValue = lhs.currentRate
                rhsValue = rhs.currentRate
            case .totalBytes:
                lhsValue = Double(lhs.totalBytes)
                rhsValue = Double(rhs.totalBytes)
            }
            if lhsValue == rhsValue {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
        visibleRows = Array(sorted.prefix(10))
        tableView.reloadData()
    }
}
