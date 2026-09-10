import Foundation

enum QuotaFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Credentials never leave this request except in the Authorization header to this fixed host.
final class CursorQuotaProvider: NSObject, URLSessionTaskDelegate {
    private static let keychainLock = NSLock()
    private static let pausedKey = "cursorCredentialReadsPaused"

    private func credential(manualRetry: Bool) throws -> String {
        Self.keychainLock.lock()
        defer { Self.keychainLock.unlock() }
        if manualRetry { UserDefaults.standard.set(false, forKey: Self.pausedKey) }
        guard !UserDefaults.standard.bool(forKey: Self.pausedKey) else {
            throw QuotaFailure.message("Cursor 凭据读取已暂停，请点击“重试 Cursor 连接”")
        }
        do {
            // Match Cursor CLI's trusted system-tool path. Never pass the token
            // in argv, persist it, print it, or alter the item's access rules.
            let result = try BoundedCommand.run(path: "/usr/bin/security", arguments: [
                "find-generic-password", "-a", "cursor-user", "-s", "cursor-access-token", "-w"
            ])
            guard result.status == 0,
                  let token = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
                throw QuotaFailure.message("Cursor 凭据不可用（退出码 \(result.status)）")
            }
            return token
        } catch {
            UserDefaults.standard.set(true, forKey: Self.pausedKey)
            throw QuotaFailure.message("Cursor 凭据读取失败或超时，已暂停自动重试；请确认 CLI 登录后手动重试")
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func read(manualRetry: Bool = false) throws -> QuotaReading {
        let token = try credential(manualRetry: manualRetry)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let done = DispatchSemaphore(value: 0)
        var reading: QuotaReading?
        var failure = "Cursor 查询超时"
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil, let http = response as? HTTPURLResponse else { failure = "Cursor 网络连接失败"; return }
            guard http.statusCode == 200 else {
                if [401, 403].contains(http.statusCode) {
                    UserDefaults.standard.set(true, forKey: Self.pausedKey)
                    failure = "Cursor 登录已过期或权限不足；已暂停，请登录 CLI 后手动重试"
                } else { failure = "Cursor 服务返回 \(http.statusCode)" }
                return
            }
            guard let data, data.count < 1_048_576, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { failure = "Cursor 数据格式无法识别"; return }
            reading = QuotaParsing.cursor(json)
            failure = "Cursor 未返回套餐额度百分比"
        }
        task.resume()
        guard done.wait(timeout: .now() + 18) == .success else { task.cancel(); throw QuotaFailure.message("Cursor 查询超时") }
        guard let reading else { throw QuotaFailure.message(failure) }
        return reading
    }
}

enum CodexQuotaProvider {
    static func read() throws -> QuotaReading {
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw QuotaFailure.message("未找到 Codex，请安装并登录") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var reading: QuotaReading?
        var finished = false
        func send(_ object: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                try? input.fileHandleForWriting.write(contentsOf: data + Data([10]))
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            guard !data.isEmpty else { finished = true; done.signal(); return }
            buffer.append(data)
            if buffer.count > 1_048_576 { finished = true; done.signal(); return }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = json["id"] as? Int else { continue }
                if id == 1 {
                    send(["method": "initialized"])
                    send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
                } else if id == 2 {
                    reading = (json["result"] as? [String: Any]).flatMap(QuotaParsing.codex)
                    finished = true; done.signal(); return
                }
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        try process.run()
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ministat", "version": "0.4.4"], "capabilities": [:]]])
        let success = done.wait(timeout: .now() + 18) == .success
        lock.lock(); finished = true; let value = reading; lock.unlock()
        guard success, let value else { throw QuotaFailure.message("Codex 查询失败或超时，请确认已登录 ChatGPT 账号") }
        return value
    }
}
