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
    /// Entries of this Mac alone, cloud storage included; nil when the core
    /// does not tell them apart. `indexedCount` adds the attached volumes.
    var localIndexedCount: Int? = nil
    /// Attached volumes being searched and cloud providers, each with its own
    /// progress. The lists of unreadable locations above cover this Mac only.
    var sources: [IndexSource] = []

    var inaccessibleCount: Int { rawInaccessiblePlaces.count }
}

/// An attached volume or a cloud provider the index is filling in.
struct IndexSource: Equatable {
    enum Kind { case externalVolume, cloudProvider }
    var id: String
    var name: String
    var kind: Kind
    var indexed: Int
    /// False while it is still being scanned or brought up to date.
    var isComplete: Bool
    /// Set when the source stopped with an error.
    var failure: String?
}

/// An attached volume the index knows about, attached now or remembered
/// from an earlier time.
struct ExternalVolume: Equatable {
    /// Stable across attachments (the volume UUID where there is one).
    var id: String
    /// The name shown to the user.
    var name: String
    var isOnline: Bool
    /// Whether its files are searched.
    var isIncluded: Bool
    /// Being scanned for the first time, or brought up to date.
    var isScanning: Bool
    /// Entries of this volume in the index.
    var indexedCount: Int
    /// A short extra line such as “exFAT · 1 TB”, or nil for none.
    var detail: String?
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

    // Attached volumes.

    /// Whether a volume attached for the first time is added to the search
    /// by itself. Volumes already known keep their own choice.
    var includesNewExternalVolumes: Bool { get set }
    /// Every known attached volume, including ones not attached right now.
    var externalVolumes: [ExternalVolume] { get }
    /// Turning a volume off stops its scan and takes its files out of the
    /// results; what was indexed stays until `removeExternalVolumeData`.
    func setExternalVolume(_ id: String, included: Bool)
    /// Deletes what was indexed for the volume and stops searching it. A
    /// volume that is not attached is then forgotten.
    func removeExternalVolumeData(_ id: String)
    /// What went wrong when keeping these choices or deleting data, in the
    /// core's own words; nil when nothing did.
    var externalVolumeSettingsError: String? { get }
    /// Called, on any thread, when the list or a volume's state changed.
    var onExternalVolumesChange: (() -> Void)? { get set }
}

extension ExternalVolume {
    /// The state line under the volume's name.
    var stateLine: String {
        let count = formattedCount(indexedCount)
        if !isOnline {
            if !isIncluded { return indexedCount > 0 ? "未连接，未加入，保留 \(count) 个已收录条目" : "未连接，未加入" }
            return indexedCount > 0 ? "未连接，已收录 \(count) 个" : "未连接"
        }
        if !isIncluded { return indexedCount > 0 ? "未加入，保留 \(count) 个已收录条目" : "未加入" }
        if isScanning { return indexedCount > 0 ? "正在扫描，已收录 \(count) 个" : "正在扫描" }
        return indexedCount > 0 ? "已加入，共 \(count) 个文件" : "已加入"
    }
}

/// Explains a settings error of the core in words a user understands; the
/// core's own text follows in brackets.
func externalVolumeErrorText(_ raw: String) -> String {
    let lowered = raw.lowercased()
    let meaning: String
    if lowered.contains("remove") {
        meaning = "删除外接磁盘已收录的数据时出错，下次启动时会再试一次。"
    } else if lowered.contains("save") {
        meaning = "外接磁盘的设置没能保存，刚才的更改在重新打开软件后可能失效。"
    } else if lowered.contains("read") || lowered.contains("inspect") {
        meaning = "读不到外接磁盘的设置，暂时无法更改；可以退出后重新打开软件再试。"
    } else {
        meaning = "外接磁盘的设置出了问题。"
    }
    return "\(meaning)（原始信息：\(raw)）"
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
