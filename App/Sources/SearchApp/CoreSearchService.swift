import Foundation
import SearchCore

/// Bridges the interface protocol to the real search core running in-process.
final class CoreSearchService: SearchService {
    private let engine: SearchEngine
    var onStatusChange: ((IndexStatus) -> Void)?
    var onIndexChange: (() -> Void)?

    init() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("dev.local.filesearch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = try SearchEngine(dataDirectory: directory)
    }

    func start() {
        engine.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.onStatusChange?(Self.convert(status))
        }
        engine.onIndexChange = { [weak self] in self?.onIndexChange?() }
        engine.start()
    }

    func stop() { engine.stop() }

    func search(_ request: SearchRequest) -> SearchResponse {
        let column: SearchColumn
        switch request.sort {
        case .name: column = .name
        case .location: column = .path
        case .size: column = .size
        case .modified: column = .modified
        }
        let query = EngineQuery(text: request.text,
                                mode: request.scope == .name ? .name : .path,
                                column: column,
                                direction: request.order == .ascending ? .ascending : .descending,
                                showAll: request.includeSystemFiles,
                                offset: request.offset, limit: request.limit)
        let result = engine.search(query)
        let hits = result.hits.map {
            SearchHit(id: $0.id, name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: $0.size,
                      modified: $0.modified, isCloudPlaceholder: $0.isCloudPlaceholder,
                      isOnExternalVolume: $0.volumeID != nil)
        }
        return SearchResponse(hits: hits, total: result.total, totalIsExact: result.totalIsExact)
    }

    var status: IndexStatus { Self.convert(engine.status) }
    func recheckAccess() { engine.recheckAccess() }
    func rebuild() { engine.rebuild() }

    private static func convert(_ status: EngineStatus) -> IndexStatus {
        let phase: IndexPhase
        switch status.phase {
        case .starting: phase = .starting
        case .scanning(let indexed): phase = .scanning(indexed: indexed)
        case .ready: phase = .ready
        case .recovering: phase = .recovering
        case .supplementing(let name): phase = .supplementing(volumeName: name)
        case .failed(let reason): phase = .degraded(reason: reason)
        }
        return IndexStatus(phase: phase, indexedCount: status.indexedCount,
                           inaccessiblePaths: status.inaccessiblePaths,
                           indexBytesOnDisk: status.indexBytesOnDisk)
    }
}
