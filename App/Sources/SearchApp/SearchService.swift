import Foundation

// Types and protocol from docs/界面与核心接口约定.md. The interface layer
// depends only on these.

enum SearchScope { case name, path }
enum SortColumn { case name, location, size, modified }
enum SortOrder { case ascending, descending }

/// What kind of item to look for. The core decides by the directory flag and
/// the file name extension; see docs/里程碑4-门面验收.md.
enum SearchKind: CaseIterable {
    case any, folder, document, image, audio, video, archive, application

    /// The name in the filter menu and, except for `any`, on the filter chip.
    var title: String {
        switch self {
        case .any: return "不限"
        case .folder: return "文件夹"
        case .document: return "文稿"
        case .image: return "图片"
        case .audio: return "音频"
        case .video: return "视频"
        case .archive: return "压缩包"
        case .application: return "应用程序"
        }
    }

    var symbol: String {
        switch self {
        case .any: return "square.grid.2x2"
        case .folder: return "folder"
        case .document: return "doc.text"
        case .image: return "photo"
        case .audio: return "music.note"
        case .video: return "film"
        case .archive: return "archivebox"
        case .application: return "app"
        }
    }
}

struct SearchRequest {
    var text: String
    var scope: SearchScope = .name
    var sort: SortColumn = .name
    var order: SortOrder = .ascending
    var includeSystemFiles = false
    var kind: SearchKind = .any
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
    /// Adding an attached volume or a cloud provider; `indexed` counts what
    /// that source has published so far.
    case supplementing(name: String, indexed: Int)
    case degraded(reason: String)
}

/// Why a location could not be read.
enum AccessReason: CaseIterable {
    /// Inside a privacy-protected folder; full disk access should open it.
    case needsFullDiskAccess
    /// Ordinary file permissions or an ACL; full disk access does not change them.
    case filePermissions
    case unknown
}

/// A location the core could not read. In the summarised list `count` is the
/// number of raw locations the entry stands for; raw entries count 1.
struct InaccessiblePlace: Equatable {
    var path: String
    var count: Int
    var reason: AccessReason
}

struct IndexStatus {
    var phase: IndexPhase
    var indexedCount: Int
    /// Every location that could not be read, system folders included.
    var rawInaccessiblePlaces: [InaccessiblePlace] = []
    /// The same locations merged under common folders, per reason, for reading.
    var inaccessiblePlaces: [InaccessiblePlace] = []
    /// Other applications' data folders left unread until full disk access is
    /// granted, so that indexing never raises the system's access prompt.
    var pendingFullDiskAccessPaths: [String] = []
    /// False while the core is still checking which locations are unreadable;
    /// the lists are then empty or about to change and must not be counted.
    var inaccessibleVerified = true
    var indexBytesOnDisk: Int64

    var inaccessibleCount: Int { rawInaccessiblePlaces.count }
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

/// The query text as sent to the core: every kind of space becomes a plain
/// space, so a no-break space (Option-Space), an ideographic space or a
/// zero-width space separates terms like an ordinary one. The text shown in
/// the field is left as typed.
func normalizedQuery(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        let isSpace = scalar.properties.isWhitespace || invisibleSpaces.contains(scalar.value)
        scalars.append(isSpace ? " " : scalar)
    }
    return String(scalars)
}

/// Zero-width spaces that Unicode does not class as whitespace: zero width
/// space, word joiner, Mongolian vowel separator, byte order mark.
private let invisibleSpaces: Set<UInt32> = [0x200B, 0x2060, 0x180E, 0xFEFF]

/// Splits a query the same way the core does: space-separated terms,
/// case-insensitive, NFC.
func queryTerms(_ text: String) -> [String] {
    normalizedQuery(text).precomposedStringWithCanonicalMapping.lowercased()
        .split(separator: " ").map(String.init)
}
