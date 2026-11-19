import Foundation

// Types and protocol from docs/界面与核心接口约定.md. The interface layer
// depends only on these.

enum SearchScope { case name, path }
enum SortColumn { case name, location, size, modified }
enum SortOrder { case ascending, descending }

struct SearchRequest {
    var text: String
    var scope: SearchScope = .name
    var sort: SortColumn = .name
    var order: SortOrder = .ascending
    var includeSystemFiles = false
    var offset = 0
    var limit = 200
}

struct SearchHit {
    var id: UInt64
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date
    var isCloudPlaceholder: Bool
    var isOnExternalVolume: Bool
}

struct SearchResponse {
    var hits: [SearchHit]
    var total: Int
    var totalIsExact: Bool
}

enum IndexPhase {
    case starting
    case scanning(indexed: Int)
    case ready
    /// Checking the index against the disk, after a requested rebuild or
    /// after missed file events. Searching keeps working meanwhile.
    case recovering
    case supplementing(volumeName: String)
    case degraded(reason: String)
}

struct IndexStatus {
    var phase: IndexPhase
    var indexedCount: Int
    var inaccessiblePaths: [String]
    var indexBytesOnDisk: Int64
}

protocol SearchService: AnyObject {
    func start()
    func stop()
    func search(_ request: SearchRequest) -> SearchResponse
    var status: IndexStatus { get }
    var onStatusChange: ((IndexStatus) -> Void)? { get set }
    var onIndexChange: (() -> Void)? { get set }
    func recheckAccess()
    func rebuild()
}

/// Splits a query the same way the core does: whitespace-separated terms,
/// case-insensitive, NFC.
func queryTerms(_ text: String) -> [String] {
    text.precomposedStringWithCanonicalMapping.lowercased()
        .split(whereSeparator: \.isWhitespace).map(String.init)
}
