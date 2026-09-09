import Foundation
import Darwin

enum CommandFailure: Error { case timeout, outputTooLarge, readTimeout }

// No shell, inherited stdin, stderr logging, or temporary output files.
enum BoundedCommand {
    static func run(path: String, arguments: [String], timeout: TimeInterval = 5,
                    outputLimit: Int = 65_536) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var output = Data(), oversized = false
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                lock.lock()
                if output.count + chunk.count > outputLimit { oversized = true }
                if !oversized { output.append(chunk) }
                lock.unlock()
            }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) != .success
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        let readFinished = drained.wait(timeout: .now() + 1) == .success
        if timedOut { throw CommandFailure.timeout }
        guard readFinished else { throw CommandFailure.readTimeout }
        lock.lock(); defer { lock.unlock() }
        guard !oversized else { throw CommandFailure.outputTooLarge }
        return (process.terminationStatus, output)
    }
}
