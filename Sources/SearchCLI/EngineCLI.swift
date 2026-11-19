import Foundation
import SearchCore

private struct EngineCommand: Decodable {
    let op: String
    let query: String?
    let mode: QueryMode?
    let column: SearchColumn?
    let direction: SearchDirection?
    let showAll: Bool?
    let offset: Int?
    let limit: Int?

    var engineQuery: EngineQuery {
        EngineQuery(text: query ?? "", mode: mode ?? .name, column: column ?? .name,
                    direction: direction ?? .ascending, showAll: showAll ?? false,
                    offset: offset ?? 0, limit: limit ?? 50)
    }
}

private func encodeStatus(_ status: EngineStatus) -> [String: Any] {
    var result: [String: Any] = [
        "indexedCount": status.indexedCount,
        "inaccessiblePaths": status.inaccessiblePaths,
        "indexBytesOnDisk": status.indexBytesOnDisk
    ]
    switch status.phase {
    case .starting: result["phase"] = "starting"
    case .scanning: result["phase"] = "scanning"
    case .ready: result["phase"] = "ready"
    case let .supplementing(name):
        result["phase"] = "supplementing"
        result["name"] = name
    case .recovering: result["phase"] = "recovering"
    case let .failed(error):
        result["phase"] = "failed"
        result["error"] = error
    }
    return result
}

private func encodeHit(_ hit: EngineHit) -> [String: Any] {
    [
        "id": hit.id, "name": hit.name, "path": hit.path, "size": hit.size,
        "modified": hit.modified.timeIntervalSince1970, "isDirectory": hit.isDirectory,
        "isCloudPlaceholder": hit.isCloudPlaceholder, "volumeID": hit.volumeID as Any? ?? NSNull()
    ]
}

func runEngineCLI(_ args: [String]) throws {
    guard args.count == 2 else { throw CommandError.usage }
    let engine = try SearchEngine(dataDirectory: URL(fileURLWithPath: args[1], isDirectory: true))
    func write(_ event: String, _ fields: [String: Any] = [:]) throws {
        var line = fields
        line["event"] = event
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    engine.onStatusChange = { status in
        if case let .failed(error) = status.phase {
            FileHandle.standardError.write(Data((error + "\n").utf8))
        }
    }
    engine.start()
    defer { engine.stop() }
    let decoder = JSONDecoder()
    while let line = readLine() {
        let exit = try autoreleasepool {
            guard let command = try? decoder.decode(EngineCommand.self, from: Data(line.utf8)) else {
                try write("bad-command")
                return false
            }
            switch command.op {
            case "query":
                let query = command.engineQuery
                let start = DispatchTime.now().uptimeNanoseconds
                let result = engine.search(query)
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                try write("query", ["hits": result.hits.map(encodeHit), "total": result.total,
                                    "totalIsExact": result.totalIsExact, "nanoseconds": elapsed])
            case "status":
                try write("status", ["status": encodeStatus(engine.status), "cpuSeconds": usageAtProcess().0])
            case "recheck-access":
                engine.recheckAccess()
                try write("recheck-access")
            case "rebuild":
                engine.rebuild()
                try write("rebuild")
            case "quit":
                engine.stop()
                try write("quit")
                return true
            default:
                try write("bad-command")
            }
            return false
        }
        if exit { return }
    }
}
