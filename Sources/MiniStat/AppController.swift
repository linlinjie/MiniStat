import AppKit
import ServiceManagement

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private let settingsStore = SettingsStore()
    private var preferences: AppPreferences
    private var snapshot = MetricSnapshot.empty

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let metricsView = StatusBarMetricsView()
    private let menu = NSMenu()
    private var moduleItems: [MetricModule: NSMenuItem] = [:]
    private var refreshItems: [TimeInterval: NSMenuItem] = [:]
    private let loginItem = NSMenuItem(title: "MiniStat 开机启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let loginItemsSettingsItem = NSMenuItem(
        title: "查看与管理自启动应用…",
        action: #selector(openLoginItemsSettings),
        keyEquivalent: ""
    )
    private let loginErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var trafficWindowController: TrafficWindowController?
    private var quotaTimer: Timer?
    private var quotaReadings: [String: QuotaReading] = [:]
    private var quotaErrors: [String: String] = [:]
    private var quotaLoading: Set<String> = []
    private var quotaItems: [QuotaDisplay: NSMenuItem] = [:]
    private var quotaRefreshItems: [TimeInterval: NSMenuItem] = [:]
    private let quotaDetails = NSMenu(title: "额度详情")

    private let sampleQueue = DispatchQueue(label: "local.ministat.sampling", qos: .utility)
    private let collector = SystemMetricCollector()
    private var sampleTimer: DispatchSourceTimer?
    private var loginErrorMessage: String?
    private var currentStatusWidth: CGFloat = 0
    private var currentAccessibilityLabel = ""

    override init() {
        preferences = settingsStore.load()
        super.init()
        configureStatusItem()
        configureMenu()
        observePowerEvents()
        startSamplingTimer()
        startQuotaTimer()
        refreshQuotas()
    }

    deinit {
        sampleTimer?.cancel()
        quotaTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.addSubview(metricsView)
        metricsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            metricsView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            metricsView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            metricsView.topAnchor.constraint(equalTo: button.topAnchor),
            metricsView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        statusItem.menu = menu
        updateStatusView()
    }

    private func configureMenu() {
        menu.delegate = self

        for module in MetricModule.allCases {
            let item = NSMenuItem(
                title: "显示 \(module.menuTitle)",
                action: #selector(toggleModule(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = module.rawValue
            moduleItems[module] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refreshRoot = NSMenuItem(title: "系统指标刷新频率", action: nil, keyEquivalent: "")
        let refreshMenu = NSMenu(title: "刷新频率")
        for interval in AppPreferences.metricIntervals {
            let item = NSMenuItem(
                title: AppPreferences.intervalTitle(interval),
                action: #selector(changeRefreshInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = interval
            refreshItems[interval] = item
            refreshMenu.addItem(item)
        }
        menu.setSubmenu(refreshMenu, for: refreshRoot)
        menu.addItem(refreshRoot)

        let trafficItem = NSMenuItem(
            title: "应用流量 Top 10…",
            action: #selector(showApplicationTraffic),
            keyEquivalent: ""
        )
        trafficItem.target = self
        menu.addItem(trafficItem)
        let quotaRoot = NSMenuItem(title: "额度显示（剩余）", action: nil, keyEquivalent: "")
        let quotaMenu = NSMenu(title: "额度显示")
        for mode in QuotaDisplay.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changeQuotaDisplay(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue
            quotaItems[mode] = item; quotaMenu.addItem(item)
        }
        quotaRoot.submenu = quotaMenu; menu.addItem(quotaRoot)
        let detailRoot = NSMenuItem(title: "额度详情与连接…", action: nil, keyEquivalent: "")
        detailRoot.submenu = quotaDetails; menu.addItem(detailRoot)

        let quotaRefreshRoot = NSMenuItem(title: "额度刷新频率", action: nil, keyEquivalent: "")
        let quotaRefreshMenu = NSMenu(title: "额度刷新频率")
        for interval in AppPreferences.quotaIntervals {
            let item = NSMenuItem(title: AppPreferences.intervalTitle(interval), action: #selector(changeQuotaRefreshInterval(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = interval
            quotaRefreshItems[interval] = item; quotaRefreshMenu.addItem(item)
        }
        quotaRefreshRoot.submenu = quotaRefreshMenu; menu.addItem(quotaRefreshRoot)
        menu.addItem(.separator())
        let captureItem = NSMenuItem(title: "截图 / 录屏…", action: #selector(openScreenshot), keyEquivalent: "")
        captureItem.target = self
        captureItem.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图与录屏")
        menu.addItem(captureItem)

        loginItem.target = self
        menu.addItem(loginItem)
        loginItemsSettingsItem.target = self
        menu.addItem(loginItemsSettingsItem)
        loginErrorItem.isEnabled = false
        loginErrorItem.isHidden = true
        menu.addItem(loginErrorItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 MiniStat", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        refreshMenuStates()
    }

    private func observePowerEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func startSamplingTimer() {
        sampleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(
            deadline: .now(),
            repeating: preferences.refreshInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let nextSnapshot = self.collector.sample()
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = nextSnapshot
                self?.updateStatusView()
            }
        }
        sampleTimer = timer
        timer.resume()
    }

    private func updateStatusView() {
        metricsView.quotaCells = preferences.quotaDisplay.providers.flatMap { name in
            QuotaReading.statusCells(provider: name, reading: quotaReadings[name], failed: quotaErrors[name] != nil)
        }
        metricsView.update(snapshot: snapshot, visibleModules: preferences.visibleModules)
        let requiredWidth = metricsView.requiredWidth
        if currentStatusWidth != requiredWidth {
            currentStatusWidth = requiredWidth
            statusItem.length = requiredWidth
        }
        let label = accessibilityLabel
        if currentAccessibilityLabel != label {
            currentAccessibilityLabel = label
            statusItem.button?.setAccessibilityLabel(label)
        }
    }

    private var accessibilityLabel: String {
        let modules = MetricModule.allCases.filter(preferences.visibleModules.contains)
        let labels = modules.map(\.menuTitle) + metricsView.quotaCells.map { "\($0.0) 剩余 \($0.1)" }
        return labels.isEmpty ? "MiniStat 设置" : "MiniStat：" + labels.joined(separator: "、")
    }

    private func refreshMenuStates() {
        for (interval, item) in quotaRefreshItems { item.state = interval == preferences.quotaRefreshInterval ? .on : .off }
        for (mode, item) in quotaItems { item.state = mode == preferences.quotaDisplay ? .on : .off }
        rebuildQuotaDetails()
        for (module, item) in moduleItems {
            item.state = preferences.visibleModules.contains(module) ? .on : .off
        }
        for (interval, item) in refreshItems {
            item.state = preferences.refreshInterval == interval ? .on : .off
        }

        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        loginErrorItem.isHidden = loginErrorMessage == nil && status != .requiresApproval && status != .notFound
        if let loginErrorMessage {
            loginErrorItem.title = "登录项错误：\(loginErrorMessage)"
        } else if status == .requiresApproval {
            loginErrorItem.title = "请在“系统设置 › 登录项”中允许 MiniStat"
        } else if status == .notFound {
            loginErrorItem.title = "请将 MiniStat.app 移到“应用程序”后再开启"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStates()
        metricsView.menuHighlighted = true
    }

    func menuDidClose(_ menu: NSMenu) {
        metricsView.menuHighlighted = false
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let module = MetricModule(rawValue: rawValue) else { return }
        if preferences.visibleModules.contains(module) {
            preferences.visibleModules.remove(module)
        } else {
            preferences.visibleModules.insert(module)
        }
        settingsStore.save(preferences)
        updateStatusView()
        refreshMenuStates()
    }

    @objc private func changeRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval,
              AppPreferences.metricIntervals.contains(interval) else { return }
        preferences.refreshInterval = interval
        settingsStore.save(preferences)
        startSamplingTimer()
        refreshMenuStates()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            loginErrorMessage = nil
        } catch {
            loginErrorMessage = error.localizedDescription
        }
        refreshMenuStates()
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func showApplicationTraffic() {
        if trafficWindowController == nil {
            trafficWindowController = TrafficWindowController()
        }
        trafficWindowController?.show()
    }

    @objc private func systemWillSleep() {
        sampleQueue.async { [collector] in collector.resetDeltas() }
    }

    @objc private func systemDidWake() {
        sampleQueue.async { [collector] in collector.resetDeltas() }
        refreshQuotas()
    }

    @objc private func changeQuotaDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = QuotaDisplay(rawValue: raw) else { return }
        preferences.quotaDisplay = mode
        settingsStore.save(preferences)
        startQuotaTimer()
        updateStatusView(); refreshMenuStates(); refreshQuotas()
    }

    private func startQuotaTimer() {
        quotaTimer?.invalidate()
        quotaTimer = nil
        guard !preferences.quotaDisplay.providers.isEmpty else { return }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: preferences.quotaRefreshInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshQuotas() }
        }
        quotaTimer?.tolerance = min(5, preferences.quotaRefreshInterval * 0.1)
    }

    @objc private func changeQuotaRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval,
              AppPreferences.quotaIntervals.contains(interval) else { return }
        preferences.quotaRefreshInterval = interval
        settingsStore.save(preferences)
        startQuotaTimer(); refreshMenuStates()
    }

    @objc private func openScreenshot() {
        menu.cancelTracking()
        // Launch Apple's own selection/recording toolbar after the menu closes.
        // No synthetic keystrokes, screen capture, or recording until user action.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "无法打开系统截图工具"
                    alert.informativeText = "可使用 Shift + Command + 5 打开截图与录屏工具栏。"
                    alert.runModal()
                }
            }
        }
    }

    @objc private func refreshQuotas() {
        for name in preferences.quotaDisplay.providers where !quotaLoading.contains(name) {
            quotaLoading.insert(name)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result: Result<QuotaReading, Error> = Result {
                    try name == "Codex" ? CodexQuotaProvider.read() : CursorQuotaProvider().read()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.quotaLoading.remove(name)
                    switch result {
                    case .success(let reading): self.quotaReadings[name] = reading; self.quotaErrors[name] = nil
                    case .failure(let error): self.quotaErrors[name] = error.localizedDescription
                    }
                    self.updateStatusView(); self.rebuildQuotaDetails()
                }
            }
        }
        rebuildQuotaDetails()
    }

    private func rebuildQuotaDetails() {
        quotaDetails.removeAllItems()
        quotaDetails.autoenablesItems = false
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
        for name in preferences.quotaDisplay.providers {
            func label(_ title: String) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false; quotaDetails.addItem(item)
            }
            label(name + (quotaLoading.contains(name) ? " · 刷新中" : ""))
            if let reading = quotaReadings[name] {
                for window in reading.currentWindows() {
                    label("\(window.title)：剩余 \(Int(window.remaining.rounded()))%" + (window.reset.map { " · \(formatter.string(from: $0)) 重置" } ?? ""))
                }
                label("更新：\(formatter.string(from: reading.updated))" + (reading.currentWindows().isEmpty ? "（已过期）" : ""))
            }
            if let error = quotaErrors[name] { label(error) }
            quotaDetails.addItem(.separator())
        }
        let refresh = NSMenuItem(title: "立即刷新额度", action: #selector(refreshQuotas), keyEquivalent: "")
        refresh.target = self; refresh.isEnabled = !preferences.quotaDisplay.providers.isEmpty && quotaLoading.isEmpty
        quotaDetails.addItem(refresh)
        let connect = NSMenuItem(title: "Cursor 登录说明…", action: #selector(cursorLoginHelp), keyEquivalent: "")
        connect.target = self; quotaDetails.addItem(connect)
        let authorize = NSMenuItem(title: "重试 Cursor 连接", action: #selector(authorizeCursor), keyEquivalent: "")
        authorize.target = self
        authorize.isEnabled = preferences.quotaDisplay.providers.contains("Cursor") && !quotaLoading.contains("Cursor")
        quotaDetails.addItem(authorize)
    }

    @objc private func authorizeCursor() {
        guard !quotaLoading.contains("Cursor") else { return }
        quotaLoading.insert("Cursor")
        rebuildQuotaDetails()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try CursorQuotaProvider().read(manualRetry: true) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.quotaLoading.remove("Cursor")
                switch result {
                case .success(let value): self.quotaReadings["Cursor"] = value; self.quotaErrors["Cursor"] = nil
                case .failure(let error): self.quotaErrors["Cursor"] = error.localizedDescription
                }
                self.updateStatusView(); self.rebuildQuotaDetails()
            }
        }
    }

    @objc private func cursorLoginHelp() {
        let alert = NSAlert()
        alert.messageText = "连接 Cursor 额度"
        alert.informativeText = "在终端运行 agent login 完成登录，再点击“重试 Cursor 连接”。MiniStat 使用与 CLI 相同的系统 security 工具读取指定凭据，仅向 api2.cursor.sh 查询。读取失败或超过 5 秒将暂停自动重试，重新启动后也保持暂停。无需重置钥匙串或允许所有应用访问。可单独设置额度刷新频率，默认 5 分钟。"
        alert.addButton(withTitle: "打开安装说明")
        alert.addButton(withTitle: "关闭")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://cursor.com/docs/cli/installation")!)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
