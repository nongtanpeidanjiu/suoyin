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

    public init(text: String, mode: QueryMode = .name, column: SearchColumn = .name,
                direction: SearchDirection = .ascending, showAll: Bool = false,
                kind: EngineKind = .any,
                offset: Int = 0, limit: Int = 50) {
        self.text = text
        self.mode = mode
        self.column = column
        self.direction = direction
        self.showAll = showAll
        self.kind = kind
        self.offset = offset
        self.limit = limit
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
    case failed(String)
}

public struct EngineSourceStatus: Sendable, Equatable {
    public enum Kind: String, Sendable { case externalVolume, cloudProvider }

    public let id: String
    public let name: String
    public let kind: Kind
    public let indexed: Int
    public let inaccessibleLocationsVerified: Bool
    public let inaccessibleLocations: [InaccessibleLocation]
    public let rawInaccessibleLocations: [InaccessibleLocation]
    public let error: String?
    public let scan: ExternalScanStatistics?
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

    public var inaccessibleLocationCount: Int { rawInaccessibleLocations.count }
    public var pendingFullDiskAccessCount: Int { pendingFullDiskAccessPaths.count }
    public var awaitingFullDiskAccess: Bool { !pendingFullDiskAccessPaths.isEmpty }
    public var inaccessiblePaths: [String] { inaccessibleLocations.map(\.path) }
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
    private var refreshScheduled = false
    private var pendingIndex = false
    private var pendingDisk = false
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
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = dataDirectory.resolvingSymlinksInPath()
        let tracker = try ChangeTracker(root: root, snapshot: directory.appendingPathComponent("index.snapshot").path,
                                        ownData: directory.path)
        self.init(dataDirectory: directory, tracker: tracker)
    }

    init(dataDirectory: URL, tracker: ChangeTracker) {
        directory = dataDirectory
        self.tracker = tracker
        reported = EngineStatus(phase: .starting, indexedCount: 0, localIndexedCount: 0,
                                sources: [], inaccessibleLocations: [],
                                rawInaccessibleLocations: [], inaccessibleLocationsVerified: false,
                                pendingFullDiskAccessPaths: [],
                                indexBytesOnDisk: Self.diskBytes(directory))
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

    public var status: EngineStatus { lock.withLock { reported } }

    public func start() {
        lifecycle.withLock {
            guard !started, !stopped else { return }
            started = true
            tracker.start()
        }
    }

    public func stop() {
        let outcome: Result<Void, Error>? = lifecycle.withLock {
            guard started, !stopped else { return nil }
            stopped = true
            return Result { try tracker.stop() }
        }
        guard let outcome else { return }
        if case let .failure(error) = outcome {
            tracker.recordEngineFailure(String(describing: error))
        }
        // Also cover a failed write that left an older durable snapshot in place.
        scheduleRefresh(for: .disk)
    }

    public func search(_ query: EngineQuery) -> EngineResult {
        guard query.offset >= 0, query.limit > 0, query.offset <= Int.max - query.limit,
              !query.text.allSatisfy(\.isWhitespace), !query.text.utf8.contains(0) else {
            return EngineResult(hits: [], total: 0, totalIsExact: true)
        }
        let lookahead = query.offset + query.limit < Int.max
        let rows = tracker.search(query.text, mode: query.mode, column: query.column, direction: query.direction,
                                  showAll: query.showAll, kind: query.kind, offset: query.offset,
                                  limit: query.limit + (lookahead ? 1 : 0))
        if rows.isEmpty {
            return EngineResult(hits: [], total: 0, totalIsExact: query.offset == 0)
        }
        return EngineResult(hits: rows.prefix(query.limit).map(EngineHit.init),
                            total: query.offset + rows.count,
                            totalIsExact: lookahead ? rows.count <= query.limit : rows.count < query.limit)
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
            if change == .disk { pendingDisk = true }
            guard !refreshScheduled else { return }
            refreshScheduled = true
            notifications.asyncAfter(deadline: max(nextRefresh, nextIndexNotification)) { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        let (index, disk, previous) = lock.withLock {
            let pending = (pendingIndex, pendingDisk, reported)
            pendingIndex = false
            pendingDisk = false
            refreshScheduled = false
            nextRefresh = .now() + .milliseconds(250)
            return pending
        }
        let localState = tracker.engineState()
        let local = localState.status
        let external = tracker.engineExternalStates()
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
                                      rawInaccessibleLocations: raw, error: status.error, scan: status.externalScan)
        }
        let providers = Set(localState.cloudEntries.keys).union(localState.pendingProviders).union(cloudPaths.keys)
        for provider in providers.sorted() {
            let checked = verified && !localState.pendingProviders.contains(provider)
            let raw = checked ? locations(local, paths: cloudPaths[provider] ?? []) : []
            sources.append(EngineSourceStatus(id: provider, name: leafName(provider), kind: .cloudProvider,
                                              indexed: localState.cloudEntries[provider, default: 0],
                                              inaccessibleLocationsVerified: checked,
                                              inaccessibleLocations: AccessDenials.summarize(raw),
                                              rawInaccessibleLocations: raw, error: nil, scan: nil))
        }
        let bytes = disk ? Self.diskBytes(directory) : previous.indexBytesOnDisk
        let phase: EnginePhase
        if let error = local.error {
            phase = .failed(error)
        } else if local.indexReconciling || external.contains(where: { $0.state.status.indexReconciling }) {
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
                                   indexBytesOnDisk: bytes)
        let indexCallback = lock.withLock {
            reported = updated
            return indexHandler
        }
        if phase != previous.phase || count != previous.indexedCount || sources != previous.sources ||
            verified != previous.inaccessibleLocationsVerified ||
            coverageChanged || updated.pendingFullDiskAccessPaths != previous.pendingFullDiskAccessPaths ||
            bytes != previous.indexBytesOnDisk {
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
