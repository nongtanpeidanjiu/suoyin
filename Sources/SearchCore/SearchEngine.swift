import Foundation
import DarwinMetadata

public enum EngineKind: String, Sendable, CaseIterable {
    case any, folder, document, image, audio, video, archive, application

    var code: UInt8 {
        switch self {
        case .any: return UInt8(DM_KIND_ANY)
        case .folder: return UInt8(DM_KIND_FOLDER)
        case .document: return UInt8(DM_KIND_DOCUMENT)
        case .image: return UInt8(DM_KIND_IMAGE)
        case .audio: return UInt8(DM_KIND_AUDIO)
        case .video: return UInt8(DM_KIND_VIDEO)
        case .archive: return UInt8(DM_KIND_ARCHIVE)
        case .application: return UInt8(DM_KIND_APPLICATION)
        }
    }
}

public struct EngineQuery: Sendable {
    public var text: String
    public var mode: QueryMode
    public var column: SearchColumn
    public var direction: SearchDirection
    public var showAll: Bool
    public var kind: EngineKind
    public var offset: Int
    public var limit: Int
    /// Optional result-count budget for this query. The engine caps extra counting at 2,000 hits.
    public var totalCountBudget: Int?

    public init(text: String, mode: QueryMode = .name, column: SearchColumn = .name,
                direction: SearchDirection = .ascending, showAll: Bool = false,
                kind: EngineKind = .any,
                offset: Int = 0, limit: Int = 50, totalCountBudget: Int? = nil) {
        self.text = text
        self.mode = mode
        self.column = column
        self.direction = direction
        self.showAll = showAll
        self.kind = kind
        self.offset = offset
        self.limit = limit
        self.totalCountBudget = totalCountBudget
    }
}

public struct EngineHit: Sendable {
    public let id: UInt64
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
    public let isCloudPlaceholder: Bool
    public let volumeID: String?

    init(_ row: SearchRow) {
        id = UInt64(row.volumeSlot) << 32 | UInt64(row.id)
        name = row.name
        path = row.path
        isDirectory = row.attribute & Kind.mask == Kind.directory
        size = row.size
        modified = Date(timeIntervalSince1970: Double(row.modified) / 1_000_000_000)
        isCloudPlaceholder = row.attribute & (isDirectory ? Kind.dataless : Kind.pending) != 0
        volumeID = row.volumeID
    }
}

public struct EngineResult: Sendable {
    public let hits: [EngineHit]
    public let total: Int
    public let totalIsExact: Bool
}

public enum EnginePhase: Sendable, Equatable {
    case starting
    case scanning(indexed: Int)
    case ready
    case supplementing(name: String, indexed: Int)
    case recovering
    case failed(EngineFailure)
}

public struct EngineSourceStatus: Sendable, Equatable {
    public enum Kind: String, Sendable { case externalVolume, cloudProvider }
    public enum CloudProviderKind: String, Sendable { case iCloudDrive, fileProvider }

    public let id: String
    public let name: String
    public let kind: Kind
    public let indexed: Int
    public let inaccessibleLocationsVerified: Bool
    public let inaccessibleLocations: [InaccessibleLocation]
    public let rawInaccessibleLocations: [InaccessibleLocation]
    public let error: String?
    public let failure: EngineFailure?
    public let scan: ExternalScanStatistics?
    public let cloudProviderKind: CloudProviderKind?
}

public struct EngineStatus: Sendable {
    public let phase: EnginePhase
    public let indexedCount: Int
    public let localIndexedCount: Int
    public let sources: [EngineSourceStatus]
    public let inaccessibleLocations: [InaccessibleLocation]
    public let rawInaccessibleLocations: [InaccessibleLocation]
    public let inaccessibleLocationsVerified: Bool
    public let pendingFullDiskAccessPaths: [String]
    public let indexBytesOnDisk: Int64
    public let startup: EngineStartupMetrics?

    public var inaccessibleLocationCount: Int { rawInaccessibleLocations.count }
    public var pendingFullDiskAccessCount: Int { pendingFullDiskAccessPaths.count }
    public var awaitingFullDiskAccess: Bool { !pendingFullDiskAccessPaths.isEmpty }
    public var inaccessiblePaths: [String] { inaccessibleLocations.map(\.path) }
}

public struct EngineStartupMetrics: Sendable, Equatable {
    public let historyEvents: UInt64
    public let catchUpNanoseconds: UInt64?
    public let recoveryReason: String?
}

public enum EngineStopResult: Sendable, Equatable {
    case finished, deadlineExceeded
    case failed(EngineFailure)
}

public struct EngineVolume: Sendable, Equatable {
    public enum Progress: String, Sendable { case idle, restoring, scanning, failed }

    public let id: String
    public let name: String
    public let nameIsPlaceholder: Bool
    public let isOnline: Bool
    public let isIncluded: Bool
    public let isScanning: Bool
    public let indexedCount: Int
    public let retainedCount: Int?
    public let progress: Progress
    public let failure: EngineFailure?
    /// A temporary registration cannot inherit the auto-include setting or survive unplugging.
    public let requiresManualInclusion: Bool
    public let filesystem: String?
    public let capacityBytes: Int64?
    public let detail: String?

    public var canForget: Bool { !isOnline }
}

public struct EngineUnindexedVolume: Sendable, Equatable {
    public enum Kind: String, Sendable { case diskImage, network, local }
    public enum Reason: String, Sendable { case diskImagesDisabled, networkUnsupported, localVolumeUnsupported }

    public let id: String
    public let name: String
    public let kind: Kind
    public let reason: Reason
}

public enum EngineVolumeForgetResult: Sendable, Equatable {
    /// The registration and all local index data for the volume have been removed.
    case removed
    /// The request is saved and cleanup will finish after the old volume tracker stops.
    case pending
}

public enum EngineVolumeForgetError: Error, Sendable, Equatable {
    case online
    case notFound
    case unavailable
    case settings(EngineVolumeSettingsError)
}

public struct EngineVolumeSettingsError: Sendable, Equatable {
    public enum Category: String, Sendable {
        case readSettings, invalidSettings, backupSettings, writeSettings, inspectIndex, verifyIdentity, removeIndex
    }

    public let category: Category
    public let underlyingMessage: String
}

/// In-process access to the local and attached-volume indexes. One instance
/// owns the data directory. Use a fresh instance to start again after stop.
public final class SearchEngine: @unchecked Sendable {
    private let tracker: ChangeTracker
    private let directory: URL
    private let lifecycle = NSLock()
    private var started = false
    private var stopped = false

    private let lock = NSLock()
    private let notifications = DispatchQueue(label: "index.engine-notifications", qos: .utility)
    private var statusHandler: (@Sendable (EngineStatus) -> Void)?
    private var indexHandler: (@Sendable () -> Void)?
    private var volumesHandler: (@Sendable () -> Void)?
    private var reportedVolumes: [EngineVolume] = []
    private var reportedUnindexedVolumes: [EngineUnindexedVolume] = []
    private var reportedIncludesNew = false
    private var reportedVolumeError: EngineVolumeSettingsError?
    private var refreshScheduled = false
    private var pendingIndex = false
    private var pendingDisk = false
    private var pendingVolumeRemoval = false
    private var nextRefresh: DispatchTime = .now()
    private var nextIndexNotification: DispatchTime = .now()
    // The notification queue owns status delivery. A pending delivery reads
    // the newest reported state, even when progress changes several times.
    private var statusDeliveryScheduled = false
    private var nextStatusNotification: DispatchTime = .now()
    private let accessDenials = AccessDenials(home: NSHomeDirectory())
    private var reported: EngineStatus

    public convenience init(dataDirectory: URL) throws {
        try self.init(dataDirectory: dataDirectory, root: "/")
    }

    convenience init(dataDirectory: URL, root: String) throws {
        guard dataDirectory.isFileURL, dataDirectory.resolvingSymlinksInPath().path != "/" else {
            throw EngineFailure(CocoaError(.fileWriteInvalidFileName), fallback: .dataDirectoryUnavailable)
        }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw EngineFailure(error, fallback: .dataDirectoryUnavailable) }
        let directory = dataDirectory.resolvingSymlinksInPath()
        let tracker: ChangeTracker
        do {
            tracker = try ChangeTracker(root: root, snapshot: directory.appendingPathComponent("index.snapshot").path,
                                        ownData: directory.path)
        } catch { throw EngineFailure(error, dataDirectory: directory.path) }
        self.init(dataDirectory: directory, tracker: tracker)
    }

    init(dataDirectory: URL, tracker: ChangeTracker) {
        directory = dataDirectory
        self.tracker = tracker
        reported = EngineStatus(phase: .starting, indexedCount: 0, localIndexedCount: 0,
                                sources: [], inaccessibleLocations: [],
                                rawInaccessibleLocations: [], inaccessibleLocationsVerified: false,
                                pendingFullDiskAccessPaths: [],
                                indexBytesOnDisk: Self.diskBytes(directory), startup: nil)
        tracker.observeEngineChanges { [weak self] in self?.scheduleRefresh(for: $0) }
    }

    public var onStatusChange: (@Sendable (EngineStatus) -> Void)? {
        get { lock.withLock { statusHandler } }
        set { lock.withLock { statusHandler = newValue } }
    }

    public var onIndexChange: (@Sendable () -> Void)? {
        get { lock.withLock { indexHandler } }
        set { lock.withLock { indexHandler = newValue } }
    }

    public var onExternalVolumesChange: (@Sendable () -> Void)? {
        get { lock.withLock { volumesHandler } }
        set { lock.withLock { volumesHandler = newValue } }
    }

    public var includesNewExternalVolumes: Bool {
        get { tracker.externalVolumeManager?.includesNew ?? false }
        set { tracker.externalVolumeManager?.setIncludesNew(newValue) }
    }

    public var externalVolumes: [EngineVolume] { tracker.externalVolumeManager?.catalog() ?? [] }

    public var unindexedMountedVolumes: [EngineUnindexedVolume] {
        tracker.externalVolumeManager?.unindexedMountedVolumes() ?? []
    }

    /// The app's own index directory is omitted from search when it is within the scanned scope.
    public var indexDataDirectoryExclusion: String? { tracker.indexDataDirectoryExclusion }

    public var externalVolumeSettingsError: EngineVolumeSettingsError? { tracker.externalVolumeManager?.settingsError }

    public func setExternalVolume(_ id: String, included: Bool) {
        tracker.externalVolumeManager?.setIncluded(id, included: included)
    }

    public func removeExternalVolumeData(_ id: String) {
        tracker.externalVolumeManager?.removeData(id)
    }

    /// Starts a retry for a connected, included volume whose index is in error.
    @discardableResult
    public func retryExternalVolume(_ id: String) -> Bool {
        tracker.externalVolumeManager?.retry(id) ?? false
    }

    /// Forgets a disconnected volume and deletes its local snapshots, journals, and scan checkpoints.
    /// Completion of a pending request is reported through onExternalVolumesChange.
    @discardableResult
    public func forgetExternalVolume(_ id: String) throws -> EngineVolumeForgetResult {
        guard let manager = tracker.externalVolumeManager else {
            throw EngineVolumeForgetError.unavailable
        }
        return try manager.forget(id)
    }

    public var status: EngineStatus { lock.withLock { reported } }

    public func start() {
        lifecycle.withLock {
            guard !started, !stopped else { return }
            started = true
            tracker.start()
        }
    }

    /// Stops listening and saves the published changes that fit within the
    /// shutdown deadline. A caller which sees a timeout may exit immediately.
    @discardableResult
    public func stop() -> EngineStopResult {
        let running = lifecycle.withLock {
            guard started else { return false }
            stopped = true
            return true
        }
        guard running else { return .finished }
        do {
            try tracker.stop()
        } catch TrackerShutdownError.deadlineExceeded { return .deadlineExceeded }
        catch {
            let failure = EngineFailure(error, fallback: .dataDirectoryUnavailable, dataDirectory: directory.path)
            tracker.recordEngineFailure(failure)
            scheduleRefresh(for: .disk)
            return .failed(failure)
        }
        scheduleRefresh(for: .disk)
        return .finished
    }

    public func search(_ query: EngineQuery) -> EngineResult {
        guard query.offset >= 0, query.limit > 0, query.offset <= Int.max - query.limit,
              !query.text.allSatisfy(\.isWhitespace), !query.text.utf8.contains(0) else {
            return EngineResult(hits: [], total: 0, totalIsExact: true)
        }
        let pageEnd = query.offset + query.limit
        let countBudget = min(query.totalCountBudget ?? 0, 2_000)
        let searchStart = pageEnd <= countBudget ? 0 : query.offset
        let searchEnd = max(pageEnd, countBudget)
        let capacity = searchEnd - searchStart
        let lookahead = searchEnd < Int.max
        let rows = tracker.search(query.text, mode: query.mode, column: query.column, direction: query.direction,
                                  showAll: query.showAll, kind: query.kind, offset: searchStart,
                                  limit: capacity + (lookahead ? 1 : 0))
        if rows.isEmpty {
            return EngineResult(hits: [], total: 0, totalIsExact: searchStart == 0)
        }
        return EngineResult(hits: rows.dropFirst(query.offset - searchStart).prefix(query.limit).map(EngineHit.init),
                            total: searchStart + rows.count,
                            totalIsExact: lookahead ? rows.count <= capacity : rows.count < capacity)
    }

    public func recheckAccess() {
        lifecycle.withLock {
            if started && !stopped { tracker.recheckEngineAccess() }
        }
    }

    public func rebuild() {
        lifecycle.withLock {
            if started && !stopped { tracker.rebuildForEngine() }
        }
    }

    private func scheduleRefresh(for change: EngineChange) {
        lock.withLock {
            if change == .index { pendingIndex = true }
            if change == .disk || change == .volumeRemoved { pendingDisk = true }
            if change == .volumeRemoved { pendingVolumeRemoval = true }
            guard !refreshScheduled else { return }
            refreshScheduled = true
            notifications.asyncAfter(deadline: max(nextRefresh, nextIndexNotification)) { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        let (index, disk, volumeRemoved, previous) = lock.withLock {
            let pending = (pendingIndex, pendingDisk, pendingVolumeRemoval, reported)
            pendingIndex = false
            pendingDisk = false
            pendingVolumeRemoval = false
            refreshScheduled = false
            nextRefresh = .now() + .milliseconds(250)
            return pending
        }
        let localState = tracker.engineState()
        let local = localState.status
        let external = tracker.engineExternalStates()
        let (volumes, includesNew, volumeError, unindexedVolumes) =
            tracker.externalVolumeManager?.catalogState() ?? ([], false, nil, [])
        let count = localState.indexed + external.reduce(0) { $0 + $1.state.indexed }
        let verified = localState.accessChecked
        func locations(_ state: TrackingStatus, paths: [String]) -> [InaccessibleLocation] {
            paths.map { path in
                let reason = accessDenials.reason(at: path, error: state.coverageDenialErrors?[path],
                                                  missingFullDiskAccess: local.awaitingFullDiskAccess)
                return InaccessibleLocation(path: path, count: 1, reason: reason)
            }
        }
        var localPaths: [String] = []
        var cloudPaths: [String: [String]] = [:]
        for path in local.coverageRestricted {
            if let provider = tracker.cloudProvider(containing: path) { cloudPaths[provider, default: []].append(path) }
            else { localPaths.append(path) }
        }
        let raw = verified ? locations(local, paths: localPaths) : []
        let coverageChanged = raw != previous.rawInaccessibleLocations
        let restrictions = coverageChanged ? AccessDenials.summarize(raw) : previous.inaccessibleLocations
        var sources = external.map { volume in
            let status = volume.state.status
            let checked = volume.state.accessChecked
            let raw = checked ? locations(status, paths: status.coverageRestricted) : []
            return EngineSourceStatus(id: volume.id, name: volume.name, kind: .externalVolume,
                                      indexed: volume.state.indexed, inaccessibleLocationsVerified: checked,
                                      inaccessibleLocations: AccessDenials.summarize(raw),
                                      rawInaccessibleLocations: raw, error: status.error, failure: status.failure,
                                      scan: status.externalScan,
                                      cloudProviderKind: nil)
        }
        let providers = Set(localState.cloudEntries.keys).union(localState.pendingProviders).union(cloudPaths.keys)
        for provider in providers.sorted() {
            let checked = verified && !localState.pendingProviders.contains(provider)
            let raw = checked ? locations(local, paths: cloudPaths[provider] ?? []) : []
            let label = CloudRoots.display(for: provider)
            sources.append(EngineSourceStatus(id: provider, name: label.name, kind: .cloudProvider,
                                              indexed: localState.cloudEntries[provider, default: 0],
                                              inaccessibleLocationsVerified: checked,
                                              inaccessibleLocations: AccessDenials.summarize(raw),
                                              rawInaccessibleLocations: raw, error: nil, failure: nil, scan: nil,
                                              cloudProviderKind: label.kind))
        }
        let bytes = disk ? Self.diskBytes(directory) : previous.indexBytesOnDisk
        let phase: EnginePhase
        if let error = local.failure {
            phase = .failed(error)
        } else if local.indexReconciling || external.contains(where: {
            $0.state.status.failure == nil && $0.state.status.indexReconciling
        }) {
            phase = .recovering
        } else if local.phase == "starting" {
            phase = .starting
        } else if local.phase == "scan-start" || local.phase == "scan-partial" {
            phase = .scanning(indexed: localState.indexed)
        } else if let volume = external.first(where: {
            $0.state.status.phase != "caught-up" && $0.state.status.error == nil
        }) {
            phase = .supplementing(name: volume.name, indexed: volume.state.indexed)
        } else if let cloud = localState.cloudProgress {
            phase = .supplementing(name: cloud.name, indexed: cloud.indexed)
        } else {
            phase = .ready
        }
        let updated = EngineStatus(phase: phase, indexedCount: count, localIndexedCount: localState.indexed,
                                   sources: sources, inaccessibleLocations: restrictions,
                                   rawInaccessibleLocations: raw, inaccessibleLocationsVerified: verified,
                                   pendingFullDiskAccessPaths: local.pendingFullDiskAccessPaths ?? [],
                                   indexBytesOnDisk: bytes, startup: local.startupHistoryEvents.map {
            EngineStartupMetrics(historyEvents: $0, catchUpNanoseconds: local.startupCatchUpNanoseconds,
                                 recoveryReason: local.startupRecoveryReason)
        })
        let (indexCallback, volumeCallback) = lock.withLock {
            reported = updated
            let changed = volumeRemoved || volumes != reportedVolumes || unindexedVolumes != reportedUnindexedVolumes ||
                includesNew != reportedIncludesNew ||
                volumeError != reportedVolumeError
            reportedVolumes = volumes
            reportedUnindexedVolumes = unindexedVolumes
            reportedIncludesNew = includesNew
            reportedVolumeError = volumeError
            return (indexHandler, changed ? volumesHandler : nil)
        }
        if phase != previous.phase || count != previous.indexedCount || sources != previous.sources ||
            verified != previous.inaccessibleLocationsVerified ||
            coverageChanged || updated.pendingFullDiskAccessPaths != previous.pendingFullDiskAccessPaths ||
            bytes != previous.indexBytesOnDisk || updated.startup != previous.startup {
            scheduleStatusDelivery()
        }
        if index, let indexCallback {
            let deliver = lock.withLock {
                let now = DispatchTime.now()
                guard now >= nextIndexNotification else { return false }
                nextIndexNotification = now + .milliseconds(250)
                return true
            }
            if deliver { indexCallback() }
            else { scheduleRefresh(for: .index) }
        }
        volumeCallback?()
    }

    private func scheduleStatusDelivery() {
        guard !statusDeliveryScheduled else { return }
        statusDeliveryScheduled = true
        notifications.asyncAfter(deadline: nextStatusNotification) { [weak self] in
            guard let self else { return }
            self.statusDeliveryScheduled = false
            let (callback, status) = self.lock.withLock { (self.statusHandler, self.reported) }
            callback?(status)
            self.nextStatusNotification = .now() + .milliseconds(500)
        }
    }

    private static func diskBytes(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        let volumes = directory.appendingPathComponent("external-volumes", isDirectory: true)
        let external = (try? fm.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil)) ?? []
        let local = ["index.snapshot", "index.snapshot.changes", "index.snapshot.budget"].map {
            directory.appendingPathComponent($0)
        }
        return (local + external).reduce(0) { sum, file in
            guard [".snapshot", ".snapshot.changes", ".snapshot.budget", ".scanlog"].contains(where: { file.path.hasSuffix($0) }),
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { return sum }
            return sum + ((attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
