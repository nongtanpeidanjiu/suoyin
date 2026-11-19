import Foundation

public struct EngineQuery: Sendable {
    public var text: String
    public var mode: QueryMode
    public var column: SearchColumn
    public var direction: SearchDirection
    public var showAll: Bool
    public var offset: Int
    public var limit: Int

    public init(text: String, mode: QueryMode = .name, column: SearchColumn = .name,
                direction: SearchDirection = .ascending, showAll: Bool = false,
                offset: Int = 0, limit: Int = 50) {
        self.text = text
        self.mode = mode
        self.column = column
        self.direction = direction
        self.showAll = showAll
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
    case supplementing(name: String)
    case recovering
    case failed(String)
}

public struct EngineStatus: Sendable {
    public let phase: EnginePhase
    public let indexedCount: Int
    public let inaccessiblePaths: [String]
    public let awaitingFullDiskAccess: Bool
    public let indexBytesOnDisk: Int64
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
    private var lastCoverage: [String] = []
    private var lastCoverageRoots: [String] = []
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
        reported = EngineStatus(phase: .starting, indexedCount: 0, inaccessiblePaths: [], awaitingFullDiskAccess: false,
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
                                  showAll: query.showAll, offset: query.offset,
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
        let local = tracker.snapshotStatus()
        let external = tracker.engineExternalStates()
        let count = tracker.indexedEntryCount()
        let coverage = external.isEmpty ? local.coverageRestricted :
            local.coverageRestricted + external.flatMap { $0.status.coverageRestricted }
        let coverageRoots = tracker.engineCoverageRoots + external.map(\.root)
        let restrictions = coverage == lastCoverage && coverageRoots == lastCoverageRoots
            ? previous.inaccessiblePaths : Self.summarizeRestrictions(coverage, within: coverageRoots)
        lastCoverage = coverage
        lastCoverageRoots = coverageRoots
        let bytes = disk ? Self.diskBytes(directory) : previous.indexBytesOnDisk
        let phase: EnginePhase
        if let error = local.error {
            phase = .failed(error)
        } else if local.indexReconciling || external.contains(where: { $0.status.indexReconciling }) {
            phase = .recovering
        } else if local.phase == "starting" {
            phase = .starting
        } else if local.phase == "scan-start" || local.phase == "scan-partial" {
            phase = .scanning(indexed: count)
        } else if let volume = external.first(where: { $0.status.phase != "caught-up" && $0.status.error == nil }) {
            phase = .supplementing(name: volume.name)
        } else if local.cloud.pending != 0 {
            phase = .supplementing(name: tracker.engineCloudProvider() ?? "云盘")
        } else {
            phase = .ready
        }
        let updated = EngineStatus(phase: phase, indexedCount: count, inaccessiblePaths: restrictions,
                                   awaitingFullDiskAccess: local.awaitingFullDiskAccess, indexBytesOnDisk: bytes)
        let (statusCallback, indexCallback) = lock.withLock {
            reported = updated
            return (statusHandler, indexHandler)
        }
        if phase != previous.phase || count != previous.indexedCount ||
            restrictions != previous.inaccessiblePaths || updated.awaitingFullDiskAccess != previous.awaitingFullDiskAccess ||
            bytes != previous.indexBytesOnDisk {
            statusCallback?(updated)
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

    static func summarizeRestrictions(_ paths: [String], within roots: [String]) -> [String] {
        func logical(_ path: String) -> String {
            path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
        }
        let allowed = roots.map(logical)
        func isAllowed(_ path: String) -> Bool { allowed.contains { inside(path, $0) } }
        func topLevel(_ paths: Set<String>) -> Set<String> {
            paths.filter { path in
                var ancestor = path
                while ancestor != "/" {
                    ancestor = parentPath(ancestor)
                    if paths.contains(ancestor) { return false }
                }
                return true
            }
        }
        let distinct = topLevel(Set(paths.lazy.map(logical).filter(isAllowed)))
        let siblings = Dictionary(grouping: distinct, by: parentPath)
        let grouped = siblings.reduce(into: Set<String>()) { result, group in
            if group.value.count > 1 && isAllowed(group.key) { result.insert(group.key) }
            else { result.formUnion(group.value) }
        }
        return Array(topLevel(grouped).sorted().prefix(50))
    }

    private static func diskBytes(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        let volumes = directory.appendingPathComponent("external-volumes", isDirectory: true)
        let external = (try? fm.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil)) ?? []
        let local = ["index.snapshot", "index.snapshot.changes", "index.snapshot.budget"].map {
            directory.appendingPathComponent($0)
        }
        return (local + external).reduce(0) { sum, file in
            guard [".snapshot", ".snapshot.changes", ".snapshot.budget"].contains(where: { file.path.hasSuffix($0) }),
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { return sum }
            return sum + ((attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
