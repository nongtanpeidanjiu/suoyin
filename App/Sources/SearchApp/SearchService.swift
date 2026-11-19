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
    var includeSystemFiles = true
    var kind: SearchKind = .any
    var offset = 0
    /// One page; the panel asks for the next page with `offset` as the
    /// list is scrolled towards its end.
    var limit = 200
    /// Asks the core to count up to this many matches from the first one, so
    /// that a short list gets an exact total. Only the first page sets it;
    /// the core takes at most 2,000.
    var totalCountBudget: Int? = nil
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
    /// that source has published so far. `restoring` is true while an
    /// attached volume brings back what an earlier run had indexed (already
    /// searchable) rather than reading new folders.
    case supplementing(name: String, indexed: Int, restoring: Bool)
    /// The running core stopped with an error. What was indexed can still be
    /// searched; “立即重建索引” is the way out.
    case failed(IndexFailure)
    /// First launch: indexing waits until the setup guide's full disk access
    /// step is past, so the system's access prompts never come before the
    /// guide has explained them.
    case waitingForSetup
    /// The core could not be opened; `reason` is the whole line to show.
    case unavailable(reason: String)
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
    /// progress and its own unreadable locations; the lists above leave
    /// these out.
    var sources: [IndexSource] = []

    /// Every unreadable location, this Mac's and those of the sources.
    var inaccessibleCount: Int {
        rawInaccessiblePlaces.count + sources.reduce(0) { $0 + $1.rawInaccessiblePlaces.count }
    }
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
    var failure: IndexFailure?
    /// Locations inside this source that could not be read, raw and merged
    /// the same way as this Mac's; empty until `isComplete`.
    var rawInaccessiblePlaces: [InaccessiblePlace] = []
    var inaccessiblePlaces: [InaccessiblePlace] = []
}

/// An attached volume the index knows about, attached now or remembered
/// from an earlier time.
struct ExternalVolume: Equatable {
    enum Progress { case idle, restoring, scanning, failed }

    /// Stable across attachments (the volume UUID where there is one).
    var id: String
    /// The volume's name; with `nameIsPlaceholder` the first characters of
    /// its identifier instead. Show `title`.
    var name: String
    /// True for a volume known only from an earlier version's files and not
    /// attached since, whose real name is not known yet.
    var nameIsPlaceholder = false
    var isOnline: Bool
    /// Whether its files are searched.
    var isIncluded: Bool
    /// Bringing back what an earlier run indexed (already searchable while
    /// it is checked), or reading folders not indexed yet.
    var progress: Progress = .idle
    /// Entries of this volume that can be searched now; 0 while it is left
    /// out or detached.
    var indexedCount: Int
    /// Entries kept on this Mac for the volume, searched or not; nil while
    /// not counted yet, 0 when there are none.
    var retainedCount: Int?
    /// The file system as the core names it, such as “exfat”.
    var filesystem: String?
    var capacityBytes: Int64?
    /// Whether it can be taken off the list: true while it is not attached.
    var canForget = false
    /// Set by the interface while taking it off the list is under way.
    var isRemoving = false
    /// Why its scan stopped, with `progress == .failed`.
    var failure: IndexFailure? = nil
    /// No stable identifier: it cannot be recognised when attached again, so
    /// it is only listed while attached, is never added by itself, and has to
    /// be switched on by hand each time.
    var requiresManualInclusion = false

    var isScanning: Bool { progress == .restoring || progress == .scanning }
    /// Whether “重试” can help: attached, searched and stopped by an error.
    var canRetry: Bool { progress == .failed && isOnline && isIncluded && !isRemoving }
}

/// A volume attached now that is not searched and cannot be added: a disk
/// image, a network volume, or a local one the core cannot index.
struct UnindexedVolume: Equatable {
    enum Kind { case diskImage, network, local }
    enum Reason { case diskImagesDisabled, networkUnsupported, localVolumeUnsupported }

    var id: String
    var name: String
    var kind: Kind
    var reason: Reason

    var kindTitle: String {
        switch kind {
        case .diskImage: return "磁盘映像"
        case .network: return "网络磁盘"
        case .local: return "本机磁盘"
        }
    }

    var reasonText: String {
        switch reason {
        case .diskImagesDisabled:
            return "磁盘映像（.dmg 等）打开后只是临时挂载，为免反复扫描暂不收录"
        case .networkUnsupported:
            return "网络磁盘读取慢、内容由别的电脑管理，暂不支持收录"
        case .localVolumeUnsupported:
            return "这块磁盘的类型或挂载方式暂不支持收录"
        }
    }
}

/// Why the core stopped, in a few categories the interface explains in
/// plain words. Used for a core that could not be opened, for one that
/// stopped while running, and for an attached volume whose scan stopped.
struct IndexFailure: Error, Equatable {
    enum Category { case dataDirectoryUnavailable, diskRead, indexCorrupt, indexLimitExceeded, other }
    /// Where the explanation is shown, which decides what the user is told to click.
    enum Context {
        /// The core could not be opened: “重试”.
        case launch
        /// The running index stopped: “立即重建索引…” in the settings.
        case index
        /// An attached volume's scan stopped: “重试” in its menu.
        case volume
    }

    var category: Category
    /// The core's own words, for diagnosis.
    var underlyingMessage: String

    /// A few words for narrow places: the panel's status line, the menu.
    var title: String {
        switch category {
        case .dataDirectoryUnavailable: return "索引数据无法保存"
        case .diskRead: return "读取磁盘出错"
        case .indexCorrupt: return "索引数据已损坏"
        case .indexLimitExceeded: return "索引超出容量上限"
        case .other: return "索引处理出错"
        }
    }

    /// What happened, in one sentence.
    var meaning: String {
        switch category {
        case .dataDirectoryUnavailable:
            return "索引数据没法保存，可能是磁盘空间不足、索引数据文件夹没有写入权限，或者它所在的磁盘是只读的。"
        case .diskRead:
            return "读取磁盘时出错，磁盘可能已断开、正在休眠或暂时无法访问。"
        case .indexCorrupt:
            return "索引数据已损坏，搜索结果可能不全或不准。"
        case .indexLimitExceeded:
            return "要收录的项目超过了这个版本的索引能保存的上限，新的变化暂时没有记下来，已有的索引仍可搜索。"
        case .other:
            return "索引处理时出现了意外错误。"
        }
    }

    /// What to do about it, in one sentence, pointing at the button that
    /// helps where the explanation is shown.
    func remedy(_ context: Context) -> String {
        let action: String
        switch context {
        case .launch: action = "点“重试”"
        case .index: action = "点下方的“立即重建索引…”"
        case .volume: action = "在这块磁盘的“更多操作”里点“重试”"
        }
        switch category {
        case .dataDirectoryUnavailable:
            return "请腾出磁盘空间或检查索引数据文件夹的权限，然后\(action)。"
        case .diskRead:
            return "请确认磁盘连接正常、能在访达里打开，然后\(action)。"
        case .indexCorrupt:
            return context == .volume ? "请\(action)，会重新扫描这块磁盘。" : "请\(action)，从头建立索引。"
        case .indexLimitExceeded:
            switch context {
            case .launch: return "请\(action)；如果仍然出现，请把括号里的原始信息反馈给开发者。"
            case .index: return "可以在“设置 › 搜索范围”里关掉不需要搜索的其他磁盘，然后\(action)。"
            case .volume: return "可以关掉不需要搜索的其他磁盘，然后\(action)。"
            }
        case .other:
            return "请\(action)；如果反复出现，请把括号里的原始信息反馈给开发者。"
        }
    }

    /// The whole explanation: meaning, remedy, the core's words in brackets.
    func text(_ context: Context) -> String {
        let raw = underlyingMessage.isEmpty ? "" : "（原始信息：\(underlyingMessage)）"
        let lead = context == .launch ? "无法启动搜索：" : ""
        return lead + meaning + remedy(context) + raw
    }
}

protocol SearchService: AnyObject {
    /// True for the stand-in data of `--demo`.
    var isDemo: Bool { get }
    func start()
    func stop()
    func search(_ request: SearchRequest) -> SearchResponse
    var status: IndexStatus { get }
    var onStatusChange: ((IndexStatus) -> Void)? { get set }
    var onIndexChange: (() -> Void)? { get set }
    func recheckAccess()
    /// Reads every folder again. Also the way out of `.failed`: the core
    /// then drops what it cannot continue from and starts afresh.
    func rebuild()
    /// The core's own index folder, the one place left out of the search;
    /// nil when it lies outside what is indexed anyway.
    var indexDataDirectoryExclusion: String? { get }

    // Attached volumes.

    /// Whether a volume attached for the first time is added to the search
    /// by itself. Volumes already known keep their own choice.
    var includesNewExternalVolumes: Bool { get set }
    /// Every known volume besides the startup disk, including ones not
    /// attached right now and other partitions of the built-in disk.
    var externalVolumes: [ExternalVolume] { get }
    /// Volumes attached now that are not searched and cannot be added,
    /// such as disk images and network volumes.
    var unindexedMountedVolumes: [UnindexedVolume] { get }
    /// Scans a failed volume again. `completion`, on the main thread, gets
    /// false when the core refused: the volume is detached, left out, no
    /// longer failed, or being removed.
    func retryExternalVolume(_ id: String, completion: @escaping (Bool) -> Void)
    /// Turning a volume off stops its scan and takes its files out of the
    /// results; what was indexed stays until `removeExternalVolumeData`.
    func setExternalVolume(_ id: String, included: Bool)
    /// Deletes what was indexed for the volume and stops searching it. A
    /// volume that is not attached is then forgotten.
    func removeExternalVolumeData(_ id: String)
    /// Takes a volume that is not attached off the list together with what
    /// was indexed for it; attached again later, it shows up as a new volume.
    /// The row reads “正在移除…” until the core is done; a failure shows in
    /// `externalVolumeSettingsError`.
    func forgetExternalVolume(_ id: String)
    /// What went wrong when keeping these choices or deleting data; nil when
    /// nothing did.
    var externalVolumeSettingsError: ExternalVolumeSettingsError? { get }
    /// Called, on any thread, when the list or a volume's state changed.
    var onExternalVolumesChange: (() -> Void)? { get set }
}

extension SearchService {
    var isDemo: Bool { false }
}

/// Something the core could not do with the choices about attached volumes.
struct ExternalVolumeSettingsError: Equatable {
    enum Category {
        case readSettings, invalidSettings, backupSettings, writeSettings, inspectIndex, verifyIdentity, removeIndex
        /// Taking a volume off the list failed: it is attached, it is no
        /// longer known, or the core cannot do it now.
        case forgetOnline, forgetNotFound, forgetUnavailable
    }

    var category: Category
    /// The core's own words, for diagnosis.
    var underlyingMessage: String

    /// What happened in words a user understands, the core's own text
    /// following in brackets.
    var text: String {
        let meaning: String
        switch category {
        case .readSettings:
            meaning = "读不到“其他磁盘”的设置，暂时按默认设置处理；这次运行期间的更改在重新打开软件后会失效。"
        case .invalidSettings:
            meaning = "“其他磁盘”的设置文件已损坏，已改用默认设置（原文件另存了一份）；请重新选择要加入搜索的磁盘。"
        case .backupSettings:
            meaning = "“其他磁盘”的设置文件已损坏，且没能另存原文件；暂时按默认设置处理，这次运行期间的更改在重新打开软件后会失效。"
        case .writeSettings:
            meaning = "“其他磁盘”的设置没能保存，刚才的更改在重新打开软件后可能失效。"
        case .inspectIndex:
            meaning = "读不到部分磁盘已收录的数据，这些磁盘暂时无法显示保留的项目数。"
        case .verifyIdentity:
            meaning = "无法确认一块磁盘的身份，暂时没有搜索它；重新接入后会再试。"
        case .removeIndex:
            meaning = "删除磁盘已收录的数据时出错，数据仍然保留，下次打开软件时会再试一次。"
        case .forgetOnline:
            meaning = "这块磁盘现在已连接，不能从列表中移除；请先推出磁盘再试。"
        case .forgetNotFound:
            meaning = "这块磁盘已经不在记录中，列表已刷新。"
        case .forgetUnavailable:
            meaning = "现在无法从列表中移除磁盘，请稍后再试；如果一直不行，请重新打开软件。"
        }
        return underlyingMessage.isEmpty ? meaning : "\(meaning)（原始信息：\(underlyingMessage)）"
    }
}

extension ExternalVolume {
    /// The name shown to the user.
    var title: String { nameIsPlaceholder ? "磁盘 \(name)" : name }

    /// Added to the state line of a volume that cannot be remembered.
    static let manualInclusionNote = "这块磁盘无法被记住，每次接入需要手动加入"

    /// The longer word on a volume that cannot be remembered, for its tool tip.
    static let manualInclusionHelp = "这块磁盘没有稳定的标识，软件无法认出下次接入的是不是同一块盘：拔出后它会从列表中消失，再接入时需要重新手动打开开关，“自动把新接入的磁盘加入搜索”对它不起作用。"

    /// More about the row than fits on it: why it failed, why it is not
    /// remembered. Nil when there is nothing to add.
    var help: String? {
        var parts: [String] = []
        if progress == .failed, isIncluded, isOnline {
            parts.append(failure?.text(.volume) ?? "这块磁盘的扫描出错，结果可能不全。请在这块磁盘的“更多操作”里点“重试”。")
        }
        if requiresManualInclusion { parts.append(Self.manualInclusionHelp) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Whether the state line reports an error.
    var showsFailure: Bool { progress == .failed && isOnline && isIncluded && !isRemoving }

    /// “exFAT · 1 TB”, or nil when neither is known.
    var detail: String? {
        let parts = [filesystem.map(Self.filesystemName), capacityBytes.flatMap(Self.boxSize)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The file system as Disk Utility names it.
    static func filesystemName(_ raw: String) -> String {
        let names = ["apfs": "APFS", "hfs": "Mac OS 扩展", "exfat": "exFAT", "msdos": "FAT", "ntfs": "NTFS"]
        return names[raw.lowercased()] ?? raw
    }

    /// The size as printed on the box: decimal units, rounded to a whole
    /// number (one decimal below 10 TB), e.g. 999,962,312,704 B → “1 TB”,
    /// 63,864,569,856 B → “64 GB”.
    static func boxSize(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let value = Double(bytes)
        func trimmed(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        }
        if value >= 999.5e9 { return value >= 9.95e12 ? "\(Int((value / 1e12).rounded())) TB" : trimmed(value / 1e12) + " TB" }
        if value >= 999.5e6 { return "\(Int((value / 1e9).rounded())) GB" }
        if value >= 999.5e3 { return "\(Int((value / 1e6).rounded())) MB" }
        return "\(Int((value / 1e3).rounded())) KB"
    }

    /// Kept entries worth naming: nil while not counted, and for none.
    private var keptCount: Int? { retainedCount.flatMap { $0 > 0 ? $0 : nil } }

    /// The state line under the volume's name.
    var stateLine: String {
        guard requiresManualInclusion, !isRemoving else { return baseStateLine }
        return "\(baseStateLine) · \(Self.manualInclusionNote)"
    }

    private var baseStateLine: String {
        if isRemoving { return "正在移除…" }
        if !isOnline {
            return keptCount.map { "未连接，保留 \(formattedCount($0)) 个已收录项目" } ?? "未连接"
        }
        if !isIncluded {
            return keptCount.map { "未加入，保留 \(formattedCount($0)) 个已收录项目" } ?? "未加入"
        }
        switch progress {
        case .restoring:
            // What an earlier run indexed comes back at once and can be
            // searched while it is checked; nothing starts over.
            if indexedCount > 0 { return "正在恢复上次收录的内容，\(formattedCount(indexedCount)) 个已可搜索" }
            return keptCount.map { "正在恢复上次收录的 \(formattedCount($0)) 个项目" } ?? "正在恢复上次收录的内容"
        case .scanning:
            return indexedCount > 0 ? "正在扫描，已收录 \(formattedCount(indexedCount)) 个" : "正在扫描"
        case .failed:
            // What was indexed before the error can still be searched.
            return indexedCount > 0 ? "扫描中断，只收录了 \(formattedCount(indexedCount)) 个项目" : "扫描中断，还没有收录项目"
        case .idle:
            if indexedCount > 0 { return "已加入，共 \(formattedCount(indexedCount)) 个项目" }
            // Just attached or just switched on: kept entries are about to be
            // loaded.
            return keptCount.map { "已加入，正在载入已收录的 \(formattedCount($0)) 个项目" } ?? "已加入"
        }
    }

    /// Whether deleting its data would delete anything known.
    var hasRetainedData: Bool { keptCount != nil }
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
