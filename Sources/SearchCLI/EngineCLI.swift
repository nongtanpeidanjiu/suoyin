import Foundation
import SearchCore

private struct EngineCommand: Decodable {
    let op: String
    let query: String?
    let mode: QueryMode?
    let column: SearchColumn?
    let direction: SearchDirection?
    let showAll: Bool?
    let kind: String?
    let offset: Int?
    let limit: Int?
    let totalCountBudget: Int?
    let volumeID: String?
    let included: Bool?

    var engineQuery: EngineQuery {
        EngineQuery(text: query ?? "", mode: mode ?? .name, column: column ?? .name,
                    direction: direction ?? .ascending, showAll: showAll ?? false,
                    kind: kind.flatMap(EngineKind.init(rawValue:)) ?? .any,
                    offset: offset ?? 0, limit: limit ?? 50, totalCountBudget: totalCountBudget)
    }
}

private func encodeStatus(_ status: EngineStatus) -> [String: Any] {
    func encodeLocation(_ location: InaccessibleLocation) -> [String: Any] {
        ["path": location.path, "count": location.count, "reason": location.reason.rawValue]
    }
    var result: [String: Any] = [
        "indexedCount": status.indexedCount,
        "localIndexedCount": status.localIndexedCount,
        "sources": status.sources.map { source -> [String: Any] in
            var value: [String: Any] = [
                "id": source.id, "name": source.name, "kind": source.kind.rawValue, "indexed": source.indexed,
                "inaccessibleLocationsVerified": source.inaccessibleLocationsVerified,
                "inaccessibleLocations": source.inaccessibleLocations.map(encodeLocation),
                "rawInaccessibleLocations": source.rawInaccessibleLocations.map(encodeLocation)
            ]
            if let error = source.error { value["error"] = error }
            if let failure = source.failure { value["errorCategory"] = failure.category.rawValue }
            if let provider = source.cloudProviderKind { value["cloudProviderKind"] = provider.rawValue }
            if let scan = source.scan, let bytes = try? JSONEncoder().encode(scan) {
                value["scan"] = try? JSONSerialization.jsonObject(with: bytes)
            }
            return value
        },
        "inaccessiblePaths": status.inaccessiblePaths,
        "inaccessibleLocations": status.inaccessibleLocations.map(encodeLocation),
        "rawInaccessibleLocations": status.rawInaccessibleLocations.map(encodeLocation),
        "inaccessibleLocationCount": status.inaccessibleLocationCount,
        "inaccessibleLocationsVerified": status.inaccessibleLocationsVerified,
        "awaitingFullDiskAccess": status.awaitingFullDiskAccess,
        "pendingFullDiskAccessPaths": status.pendingFullDiskAccessPaths,
        "pendingFullDiskAccessCount": status.pendingFullDiskAccessCount,
        "indexBytesOnDisk": status.indexBytesOnDisk
    ]
    switch status.phase {
    case .starting: result["phase"] = "starting"
    case .scanning: result["phase"] = "scanning"
    case .ready: result["phase"] = "ready"
    case let .supplementing(name, indexed):
        result["phase"] = "supplementing"
        result["name"] = name
        result["indexed"] = indexed
    case .recovering: result["phase"] = "recovering"
    case let .failed(error):
        result["phase"] = "failed"
        result["error"] = error.underlyingMessage
        result["errorCategory"] = error.category.rawValue
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
    // Match the preview application's query scheduling during measurements.
    let queries = DispatchQueue(label: "index.cli-query", qos: .userInteractive)
    func write(_ event: String, _ fields: [String: Any] = [:]) throws {
        var line = fields
        line["event"] = event
        var data = try JSONSerialization.data(withJSONObject: line)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    engine.onStatusChange = { status in
        if case let .failed(error) = status.phase {
            FileHandle.standardError.write(Data((error.underlyingMessage + "\n").utf8))
        }
        for source in status.sources {
            if let error = source.error { FileHandle.standardError.write(Data((error + "\n").utf8)) }
        }
    }
    engine.onExternalVolumesChange = { [weak engine] in
        if let error = engine?.externalVolumeSettingsError {
            FileHandle.standardError.write(Data((error.category.rawValue + ": " + error.underlyingMessage + "\n").utf8))
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
                guard command.kind == nil || command.kind.flatMap(EngineKind.init(rawValue:)) != nil else {
                    try write("bad-command")
                    return false
                }
                let query = command.engineQuery
                var measured: (EngineResult, UInt64)?
                let work = DispatchWorkItem {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = engine.search(query)
                    measured = (result, DispatchTime.now().uptimeNanoseconds - start)
                }
                queries.async(execute: work)
                work.wait()
                guard let (result, elapsed) = measured else { throw CommandError.usage }
                try write("query", ["hits": result.hits.map(encodeHit), "total": result.total,
                                    "totalIsExact": result.totalIsExact, "nanoseconds": elapsed])
            case "status":
                try write("status", ["status": encodeStatus(engine.status), "cpuSeconds": usageAtProcess().0])
            case "volumes":
                let rows: [[String: Any]] = engine.externalVolumes.map {
                    ["id": $0.id, "name": $0.name, "isOnline": $0.isOnline, "isIncluded": $0.isIncluded,
                     "isScanning": $0.isScanning, "indexedCount": $0.indexedCount,
                     "nameIsPlaceholder": $0.nameIsPlaceholder, "progress": $0.progress.rawValue,
                     "retainedCount": $0.retainedCount as Any? ?? NSNull(),
                     "filesystem": $0.filesystem as Any? ?? NSNull(),
                     "capacityBytes": $0.capacityBytes as Any? ?? NSNull(),
                     "detail": $0.detail as Any? ?? NSNull()]
                }
                let error = engine.externalVolumeSettingsError.map {
                    ["category": $0.category.rawValue, "underlyingMessage": $0.underlyingMessage]
                }
                try write("volumes", ["volumes": rows, "includesNew": engine.includesNewExternalVolumes,
                                      "error": error as Any? ?? NSNull()])
            case "set-volume":
                guard let id = command.volumeID, let included = command.included else {
                    try write("bad-command"); return false
                }
                engine.setExternalVolume(id, included: included)
                try write("set-volume")
            case "include-new-external":
                guard let included = command.included else { try write("bad-command"); return false }
                engine.includesNewExternalVolumes = included
                try write("include-new-external")
            case "remove-volume":
                guard let id = command.volumeID else { try write("bad-command"); return false }
                engine.removeExternalVolumeData(id)
                try write("remove-volume")
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
