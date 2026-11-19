import Darwin
import Foundation
import SearchCore

struct Request: Codable {
    let label: String
    let query: String
    let mode: QueryMode
    let column: SearchColumn
    let direction: SearchDirection
    let showAll: Bool
    let offset: Int
}

struct Result: Encodable {
    let label: String
    let milliseconds: [Double]
    let rows: [SearchRow]
    let consistent: Bool
}

enum CommandError: Error { case usage, resultChanged }

private let started = DispatchTime.now().uptimeNanoseconds
private func elapsed(_ since: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - since) / 1_000_000
}

private func report<T: Encodable>(_ value: T) throws {
    let json = try JSONEncoder().encode(value)
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data([10]))
}

private func integer(_ text: String, limit: Int) throws -> Int {
    guard let n = Int(text), n > 0, n <= limit else { throw CommandError.usage }
    return n
}

private func firstPage(_ index: SearchIndex, request: Request, direct: Bool) -> [SearchRow] {
    if direct {
        return index.directSearch(request.query, mode: request.mode, column: request.column,
                                  direction: request.direction, showAll: request.showAll, offset: request.offset)
    }
    return index.search(request.query, mode: request.mode, column: request.column,
                        direction: request.direction, showAll: request.showAll, offset: request.offset)
}

private let probe = Request(label: "scan-ready", query: "a", mode: .name, column: .name,
                            direction: .ascending, showAll: true, offset: 0)

private struct Progress: Encodable {
    let mark: ScanMark
    let returned: [SearchRow]
    let elapsedMilliseconds: Double
}

private func run(_ args: [String]) throws {
    guard let command = args.first else { throw CommandError.usage }
    switch command {
    case "track":
        try runTrackingCLI(args)
    case "engine":
        try runEngineCLI(args)
    case "prepare-cache":
        guard args.count == 3 else { throw CommandError.usage }
        var index = try SearchIndex.load(from: args[1])
        let loaded = SearchIndex.residentBytes()
        let loadTime = elapsed(started)
        index.prepare()
        let prepared = SearchIndex.residentBytes()
        let prepareTime = elapsed(started)
        try index.savePrepared(to: args[2])
        try report(["loadedBytes": Double(loaded), "preparedBytes": Double(prepared),
                    "maxBytes": Double(usageAtProcess().1), "loadMS": loadTime,
                    "preparedMS": prepareTime, "savedMS": elapsed(started)])
    case "inspect-cache":
        guard args.count == 2 else { throw CommandError.usage }
        let index = try SearchIndex.loadTrackedIndex(from: args[1])
        try report(index.volumes)
        try report(index.restoredRows())
    case "scan":
        guard (5...6).contains(args.count) else { throw CommandError.usage }
        let ordinary = args.count == 6 && args[5] == "--ordinary"
        let index = try SearchIndex.scan(root: args[1], ordinary: ordinary) { mark, prefix in
            switch mark.phase {
            case "partial", "local_complete":
                var index = prefix
                let partial = mark.phase == "partial"
                if !partial { index.prepare() }
                let results = firstPage(index, request: probe, direct: partial)
                let completed = elapsed(started)
                try report(Progress(mark: mark, returned: results, elapsedMilliseconds: completed))
                try prefix.save(to: partial ? args[3] : args[4])
            default:
                try report(Progress(mark: mark, returned: [], elapsedMilliseconds: elapsed(started)))
            }
        }
        try index.save(to: args[2])
    case "import":
        guard args.count == 3 else { throw CommandError.usage }
        let index = try SearchIndex.importResearchCorpus(from: args[1])
        let saveStart = DispatchTime.now().uptimeNanoseconds
        try index.save(to: args[2])
        try report(["saveMilliseconds": elapsed(saveStart), "rows": Double(index.recordCount),
                    "residentBytes": Double(SearchIndex.residentBytes())])
    case "synthetic":
        guard args.count == 3 else { throw CommandError.usage }
        try SearchIndex.millionHitCorpus(count: integer(args[1], limit: 2_200_000)).save(to: args[2])
    case "ready", "roundtrip":
        guard args.count == (command == "ready" ? 2 : 3) else { throw CommandError.usage }
        var index = try SearchIndex.load(from: args[1])
        let loaded = elapsed(started)
        index.prepare()
        let rows = index.restoredSearch("a", showAll: true)
        let ready = elapsed(started)
        try report(["loadedMilliseconds": loaded, "readyMilliseconds": ready,
                    "rows": Double(rows.count), "residentBytes": Double(SearchIndex.residentBytes()),
                    "peakBytes": Double(usageAtProcess().1)])
        try report(rows)
        if command == "roundtrip" {
            let saveStart = DispatchTime.now().uptimeNanoseconds
            try index.saveAsLoaded(to: args[2])
            try report(["saveMilliseconds": elapsed(saveStart)])
        }
    case "verify-recovery":
        guard args.count == 3 else { throw CommandError.usage }
        var rebuilt = false
        let result = try SearchIndex.loadOrRebuild(from: args[1]) {
            rebuilt = true
            return try SearchIndex.scan(root: args[2], workers: 1)
        }
        try report(["rebuilt": rebuilt, "searchable": !result.directSearch("").isEmpty])
    case "replay":
        guard (4...5).contains(args.count) else { throw CommandError.usage }
        var index = try SearchIndex.load(from: args[1])
        let direct = args.count == 5 && args[4] == "--direct"
        if !direct { index.prepare() }
        let requests = try JSONDecoder().decode([Request].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let repetitions = try integer(args[3], limit: 100)
        var firstRows = [[SearchRow]?](repeating: nil, count: requests.count)
        var times = [[Double]](repeating: [], count: requests.count)
        for iteration in 0..<repetitions {
            for i in requests.indices {
                let slot = (i + iteration) % requests.count
                let begin = DispatchTime.now().uptimeNanoseconds
                let rows = firstPage(index, request: requests[slot], direct: direct)
                times[slot].append(elapsed(begin))
                if let prior = firstRows[slot], prior != rows { throw CommandError.resultChanged }
                firstRows[slot] = rows
            }
        }
        for i in requests.indices {
            try report(Result(label: requests[i].label, milliseconds: times[i], rows: firstRows[i] ?? [], consistent: true))
        }
        try report(["residentBytes": SearchIndex.residentBytes()])
    default: throw CommandError.usage
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
