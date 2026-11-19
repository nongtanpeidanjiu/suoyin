import Foundation

/// The one service the interface talks to. It holds the real core, the
/// demo data, or, when the core could not be opened, only the reason, which
/// it reports as the status until “重试” opens the core after all. It never
/// falls back to the demo data on its own.
///
/// On the first launch it also keeps the core from starting until the setup
/// guide's full disk access step is past (`release()`): indexing reads the
/// Desktop, Documents and Downloads folders, and without access the system
/// would ask about each of them before the guide had explained anything.
final class ServiceHost: SearchService {
    private let open: () throws -> SearchService
    private var inner: SearchService?
    /// The line shown while the core cannot be opened.
    private var failure: String?
    private var startRequested = false
    private var started = false
    private var holding: Bool

    var onStatusChange: ((IndexStatus) -> Void)?
    var onIndexChange: (() -> Void)?
    var onExternalVolumesChange: (() -> Void)?

    /// `holding` keeps the core from starting until `release()`.
    init(holding: Bool, open: @escaping () throws -> SearchService) {
        self.holding = holding
        self.open = open
        connect()
    }

    var isDemo: Bool { inner?.isDemo ?? false }
    var isHolding: Bool { holding && failure == nil }

    private func connect() {
        do {
            let service = try open()
            service.onStatusChange = { [weak self] status in
                guard let self else { return }
                self.onStatusChange?(self.shown(status))
            }
            service.onIndexChange = { [weak self] in self?.onIndexChange?() }
            service.onExternalVolumesChange = { [weak self] in self?.onExternalVolumesChange?() }
            inner = service
            failure = nil
        } catch {
            inner = nil
            failure = Self.describe(error)
        }
    }

    /// “无法启动搜索：<what it means>（原始信息：<the error>）”.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        let meaning: String
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue):
            meaning = "磁盘空间不足，没能保存索引数据"
        case (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue),
             (NSCocoaErrorDomain, CocoaError.fileWriteNoPermission.rawValue),
             (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
            meaning = "没有权限读写索引数据所在的文件夹"
        case (NSCocoaErrorDomain, CocoaError.fileWriteVolumeReadOnly.rawValue),
             (NSPOSIXErrorDomain, Int(EROFS)):
            meaning = "索引数据所在的磁盘是只读的"
        default:
            meaning = "没能打开索引数据"
        }
        let raw = "\(error.domain) \(error.code)：\(error.localizedDescription)"
        return "无法启动搜索：\(meaning)（原始信息：\(raw)）"
    }

    /// The status as the interface should see it: the failure, or the wait
    /// for the setup guide, over whatever the core says.
    private func shown(_ status: IndexStatus) -> IndexStatus {
        if let failure {
            return IndexStatus(phase: .unavailable(reason: failure), indexedCount: 0, indexBytesOnDisk: 0)
        }
        guard !started else { return status }
        var waiting = status
        if holding { waiting.phase = .waitingForSetup }
        // Nothing has been checked yet, so nothing can be counted as unreadable.
        waiting.inaccessibleVerified = false
        return waiting
    }

    // MARK: Starting

    func start() {
        startRequested = true
        startIfAllowed()
    }

    /// The setup guide's access step is past: indexing may begin.
    func release() {
        guard holding else { return }
        holding = false
        startIfAllowed()
        announce()
    }

    /// Tries to open the core again after it failed.
    func retry() {
        guard failure != nil else { return }
        connect()
        startIfAllowed()
        announce()
        onExternalVolumesChange?()
        onIndexChange?()
    }

    private func startIfAllowed() {
        guard startRequested, !holding, !started, let inner else { return }
        started = true
        inner.start()
    }

    private func announce() { onStatusChange?(status) }

    func stop() { if started { inner?.stop() } }

    // MARK: Forwarded

    var status: IndexStatus {
        if let inner { return shown(inner.status) }
        return shown(IndexStatus(phase: .starting, indexedCount: 0, indexBytesOnDisk: 0))
    }

    func search(_ request: SearchRequest) -> SearchResponse {
        guard started, let inner else { return SearchResponse(hits: [], total: 0, totalIsExact: true) }
        return inner.search(request)
    }

    func recheckAccess() { if started { inner?.recheckAccess() } }
    func rebuild() { if started { inner?.rebuild() } }

    var includesNewExternalVolumes: Bool {
        get { inner?.includesNewExternalVolumes ?? false }
        set { inner?.includesNewExternalVolumes = newValue }
    }
    var externalVolumes: [ExternalVolume] { inner?.externalVolumes ?? [] }
    func setExternalVolume(_ id: String, included: Bool) { inner?.setExternalVolume(id, included: included) }
    func removeExternalVolumeData(_ id: String) { inner?.removeExternalVolumeData(id) }
    func forgetExternalVolume(_ id: String) { inner?.forgetExternalVolume(id) }
    var externalVolumeSettingsError: ExternalVolumeSettingsError? { inner?.externalVolumeSettingsError }
}
