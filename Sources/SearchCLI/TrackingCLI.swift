import Darwin
import Foundation
import SearchCore

private struct LineCommand: Decodable {
    let op: String
    let query: String?
    let mode: QueryMode?
    let column: SearchColumn?
    let direction: SearchDirection?
    let limit: Int?
    let offset: Int?
}

private struct Line: Encodable {
    let event: String
    let time: UInt64
    let cpu: Double
    let residentBytes: UInt64
    let peakBytes: Int
    let status: TrackingStatus
    var rows: [SearchRow]?
    var queryStart: UInt64?
    var queryEnd: UInt64?
    var beforeGeneration: UInt64?
    var beforeApplying: Bool?
    var intervals: [ApplyInterval]?
    var queuedEvent: UInt64?
    var processMetrics: [String: UInt64]?
    var indexBytes: [String: Int]?
}

func usageAtProcess() -> (Double, Int) {
    var info = rusage()
    getrusage(RUSAGE_SELF, &info)
    let cpu = Double(info.ru_utime.tv_sec) + Double(info.ru_stime.tv_sec) +
        Double(info.ru_utime.tv_usec + info.ru_stime.tv_usec) / 1_000_000
    return (cpu, info.ru_maxrss)
}

func runTrackingCLI(_ args: [String]) throws {
    guard args.count == 4 else { throw CommandError.usage }
    let tracker = try ChangeTracker(root: args[1], snapshot: args[2], ownData: args[3])
    let stdout = NSLock()
    func announce(_ name: String, rows: [SearchRow]? = nil, queryStart: UInt64? = nil,
                  queryEnd: UInt64? = nil, before: TrackingStatus? = nil,
                  intervals: [ApplyInterval]? = nil, queuedEvent: UInt64? = nil) {
        let info = usageAtProcess()
        let measure = name == "status" || name == "ready" || name == "rebuilt" || name == "quit"
        let components = name == "status" ? tracker.memoryBreakdown() : nil
        let line = Line(event: name, time: DispatchTime.now().uptimeNanoseconds, cpu: info.0,
                        residentBytes: SearchIndex.residentBytes(), peakBytes: info.1,
                        status: tracker.snapshotStatus(), rows: rows, queryStart: queryStart,
                        queryEnd: queryEnd, beforeGeneration: before?.generation, beforeApplying: before?.applying,
                        intervals: intervals, queuedEvent: queuedEvent,
                        processMetrics: measure ? ChangeTracker.processMetrics() : nil, indexBytes: components)
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(10)
        stdout.withLock { FileHandle.standardOutput.write(data) }
    }
    let allowedFaults = args[1].hasPrefix(FileManager.default.currentDirectoryPath + "/.m2-tmp/")
    let holdPartial = allowedFaults && ProcessInfo.processInfo.environment["M2_HOLD_PARTIAL"] == "1"
    let scanGate = DispatchSemaphore(value: 0)
    var gateUsed = false
    tracker.start { phase in
        if phase == "ready" {
            announce(phase, rows: tracker.search("a", showAll: true))
        } else {
            announce(phase)
        }
        if phase == "scan-partial" && holdPartial && !gateUsed {
            gateUsed = true
            _ = scanGate.wait(timeout: .now() + .seconds(10))
        }
        if phase == "error" { exit(20) }
    }

    while let text = readLine() {
        let quit = try autoreleasepool { () throws -> Bool in
            let command: LineCommand
            do { command = try JSONDecoder().decode(LineCommand.self, from: Data(text.utf8)) }
            catch { announce("bad-command"); return false }
            switch command.op {
            case "query":
                let before = tracker.snapshotStatus()
                let start = DispatchTime.now().uptimeNanoseconds
                let rows = tracker.search(command.query ?? "", mode: command.mode ?? .name,
                                          column: command.column ?? .name, direction: command.direction ?? .ascending,
                                          showAll: true, offset: command.offset ?? 0, limit: command.limit ?? 50)
                let end = DispatchTime.now().uptimeNanoseconds
                announce("query", rows: rows, queryStart: start, queryEnd: end, before: before)
            case "status": announce("status")
            case "sync": tracker.synchronize(); announce("sync")
            case "save": try tracker.save(); announce("save")
            case "trace-start": tracker.beginApplyTrace(); announce("trace-start")
            case "trace-end": announce("trace-end", intervals: tracker.endApplyTrace())
            case "queued-event" where allowedFaults:
                announce("queued-event", queuedEvent: tracker.queuedEventID(at: command.query ?? ""))
            case "continue-scan" where holdPartial: scanGate.signal(); announce("continue-scan")
            case "hold" where allowedFaults: tracker.holdUpdates(true); announce("hold")
            case "resume" where allowedFaults: tracker.holdUpdates(false); announce("resume")
            case "invalidate-history" where allowedFaults: tracker.simulateDroppedHistory(); announce("invalidated")
            case "pause-before-replace" where allowedFaults:
                try tracker.compactForTesting(beforeReplace: {
                    announce("before-replace")
                    Darwin.raise(SIGSTOP)
                })
            case "pause-after-replace" where allowedFaults:
                try tracker.compactForTesting(afterReplace: {
                    announce("after-replace")
                    Darwin.raise(SIGSTOP)
                })
            case "quit":
                try tracker.stop()
                announce("quit")
                return true
            default: announce("bad-command")
            }
            return false
        }
        if quit { return }
    }
    try tracker.stop()
}
