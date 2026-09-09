import Foundation

@_silgen_name("proc_pidpath")
private func processPath(_ processID: Int32, _ buffer: UnsafeMutableRawPointer?, _ bufferSize: UInt32) -> Int32

final class ProcessTrafficMonitor {
    typealias UpdateHandler = ([ApplicationTraffic]) -> Void
    typealias ErrorHandler = (String) -> Void

    private let queue = DispatchQueue(label: "local.ministat.process-traffic", qos: .utility)
    private let accumulator = ProcessTrafficAccumulator()
    private var process: Process?
    private var stopping = true
    private var generation: UInt64 = 0
    private var resolvedNames: [String: String] = [:]
    private var onUpdate: UpdateHandler?
    private var onError: ErrorHandler?

    func start(onUpdate: @escaping UpdateHandler, onError: @escaping ErrorHandler) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.generation &+= 1
            self.stopping = false
            self.accumulator.reset()
            self.resolvedNames.removeAll(keepingCapacity: true)
            self.onUpdate = onUpdate
            self.onError = onError
            self.launchSnapshot(generation: self.generation)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func launchSnapshot(generation: UInt64) {
        guard !stopping, generation == self.generation else { return }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-P", "-L", "1", "-n", "-x",
            "-J", "bytes_in,bytes_out"
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] finishedProcess in
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            self?.queue.async { [weak self] in
                self?.snapshotFinished(
                    process: finishedProcess,
                    output: output,
                    errorOutput: errorOutput,
                    generation: generation
                )
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            reportError(error.localizedDescription)
            stopping = true
        }
    }

    private func snapshotFinished(
        process: Process,
        output: Data,
        errorOutput: Data,
        generation: UInt64
    ) {
        guard !stopping, generation == self.generation else { return }
        self.process = nil

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            reportError(detail.isEmpty ? "nettop 已停止（状态码 \(process.terminationStatus)）" : detail)
            stopping = true
            return
        }

        let counters = parseSnapshot(output)
        let rows = accumulator.ingest(counters, at: ProcessInfo.processInfo.systemUptime)
        onUpdate?(rows)

        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.launchSnapshot(generation: generation)
        }
    }

    private func parseSnapshot(_ data: Data) -> [ProcessTrafficCounter] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let record = NettopCSVParser.parseRecord(String(line)) else { return nil }
            let resolvedName = resolvedNames[record.identity] ?? resolveApplicationName(for: record)
            resolvedNames[record.identity] = resolvedName
            return ProcessTrafficCounter(
                processName: resolvedName,
                processID: record.processID,
                receivedBytes: record.receivedBytes,
                sentBytes: record.sentBytes
            )
        }
    }

    private func stopLocked() {
        stopping = true
        generation &+= 1
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        onUpdate = nil
        onError = nil
    }

    private func reportError(_ message: String) {
        onError?(message)
    }

    private func resolveApplicationName(for counter: ProcessTrafficCounter) -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBytes { bytes in
            processPath(counter.processID, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return counter.processName }
        return ProcessApplicationName.resolve(
            executablePath: String(cString: buffer),
            fallback: counter.processName
        )
    }

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }
}
