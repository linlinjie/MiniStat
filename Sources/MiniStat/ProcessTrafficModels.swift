import Foundation

struct ProcessTrafficCounter: Equatable {
    let processName: String
    let processID: Int32
    let receivedBytes: UInt64
    let sentBytes: UInt64

    var identity: String { "\(processID):\(processName)" }
}

struct ApplicationTraffic: Equatable {
    let name: String
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let downloadedBytes: UInt64
    let uploadedBytes: UInt64

    var currentRate: Double { downloadBytesPerSecond + uploadBytesPerSecond }
    var totalBytes: UInt64 { downloadedBytes + uploadedBytes }
}

enum TrafficSortMode {
    case currentRate
    case totalBytes
}

enum ProcessApplicationName {
    static func resolve(executablePath: String, fallback: String) -> String {
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let appComponent = components.first(where: { $0.hasSuffix(".app") }) else {
            return fallback
        }
        let name = String(appComponent.dropLast(4))
        return name.isEmpty ? fallback : name
    }
}

enum NettopCSVParser {
    static func parseRecord(_ line: String) -> ProcessTrafficCounter? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 4,
              fields.last?.isEmpty == true,
              let receivedBytes = UInt64(fields[fields.count - 3]),
              let sentBytes = UInt64(fields[fields.count - 2]) else {
            return nil
        }

        let rawIdentity = fields[..<(fields.count - 3)].joined(separator: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = rawIdentity.lastIndex(of: "."),
              let processID = Int32(rawIdentity[rawIdentity.index(after: separator)...]) else {
            return nil
        }

        var processName = String(rawIdentity[..<separator])
        if processName.hasPrefix("\"") && processName.hasSuffix("\"") {
            processName.removeFirst()
            processName.removeLast()
        }
        guard !processName.isEmpty else { return nil }

        return ProcessTrafficCounter(
            processName: processName,
            processID: processID,
            receivedBytes: receivedBytes,
            sentBytes: sentBytes
        )
    }
}

final class ProcessTrafficAccumulator {
    private var previousCounters: [String: ProcessTrafficCounter] = [:]
    private var totals: [String: (download: UInt64, upload: UInt64)] = [:]
    private var previousSampleTime: TimeInterval?

    func reset() {
        previousCounters.removeAll(keepingCapacity: true)
        totals.removeAll(keepingCapacity: true)
        previousSampleTime = nil
    }

    func ingest(_ counters: [ProcessTrafficCounter], at sampleTime: TimeInterval) -> [ApplicationTraffic] {
        let elapsed = previousSampleTime.map { sampleTime - $0 }
        var rates: [String: (download: Double, upload: Double)] = [:]

        if let elapsed, elapsed > 0 {
            for counter in counters {
                guard let previous = previousCounters[counter.identity],
                      counter.receivedBytes >= previous.receivedBytes,
                      counter.sentBytes >= previous.sentBytes else { continue }

                let received = counter.receivedBytes - previous.receivedBytes
                let sent = counter.sentBytes - previous.sentBytes
                guard received > 0 || sent > 0 else { continue }

                let currentRate = rates[counter.processName, default: (0, 0)]
                rates[counter.processName] = (
                    currentRate.download + Double(received) / elapsed,
                    currentRate.upload + Double(sent) / elapsed
                )

                let currentTotal = totals[counter.processName, default: (0, 0)]
                totals[counter.processName] = (
                    addingWithoutOverflow(currentTotal.download, received),
                    addingWithoutOverflow(currentTotal.upload, sent)
                )
            }
        }

        previousCounters = Dictionary(uniqueKeysWithValues: counters.map { ($0.identity, $0) })
        previousSampleTime = sampleTime

        let names = Set(totals.keys).union(rates.keys)
        return names.map { name in
            let rate = rates[name, default: (0, 0)]
            let total = totals[name, default: (0, 0)]
            return ApplicationTraffic(
                name: name,
                downloadBytesPerSecond: rate.download,
                uploadBytesPerSecond: rate.upload,
                downloadedBytes: total.download,
                uploadedBytes: total.upload
            )
        }
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}
