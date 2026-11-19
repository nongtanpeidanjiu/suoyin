import Foundation

struct RecoveryTiming {
    var quietWindow: UInt64 = 5 * ReplayLag.second
    var maximumWait: UInt64 = 120 * ReplayLag.second
    var minimumInterval: UInt64 = 600 * ReplayLag.second
}

/// Only the arrival time of the 200th most recent event can delay recovery.
/// Keep counts per callback so a large batch takes a single slot.
struct EventActivity {
    private static let threshold = 200
    private var receipts: [(time: UInt64, count: Int)] = []
    private var count = 0

    mutating func received(_ events: Int, at time: UInt64) {
        guard events > 0 else { return }
        let added = min(events, Self.threshold)
        receipts.append((time, added))
        count += added
        while let first = receipts.first, count - first.count >= Self.threshold {
            count -= receipts.removeFirst().count
        }
    }

    func deadline(since: UInt64, lastStart: UInt64?, timing: RecoveryTiming) -> UInt64 {
        let busyUntil = count >= Self.threshold ? receipts[0].time + timing.quietWindow : 0
        let quiet = max(since + timing.quietWindow, busyUntil)
        return max(lastStart.map { $0 + timing.minimumInterval } ?? 0, min(quiet, since + timing.maximumWait))
    }
}

struct ReplayLag {
    static let second: UInt64 = 1_000_000_000
    static let margin = 10 * second

    private var baseline: UInt64?
    private var points: [(time: UInt64, event: UInt64)] = []

    init(baseline: UInt64? = nil) { self.baseline = baseline }

    mutating func record(_ event: UInt64, at time: UInt64) {
        let cut = time >= Self.margin ? time - Self.margin : nil
        while let cut, let first = points.first, first.time <= cut {
            baseline = max(baseline ?? 0, points.removeFirst().event)
        }
        if let last = points.last, last.time / Self.second == time / Self.second {
            points.removeLast()
        }
        points.append((time, event))
    }

    mutating func confirmHistory(through event: UInt64) { baseline = max(baseline ?? 0, event) }

    func position(at time: UInt64, observed: UInt64?, pending: UInt64?) -> UInt64? {
        guard let observed else { return nil }
        let aged = time >= Self.margin
            ? points.last(where: { $0.time <= time - Self.margin })?.event : nil
        guard aged != nil || baseline != nil else { return nil }
        let safe = max(aged ?? 0, baseline ?? 0)
        let limit = min(observed, safe, pending.map { $0 > 0 ? $0 - 1 : 0 } ?? .max)
        return limit == 0 ? nil : limit
    }
}

struct BaseWriteBudget {
    static let window: TimeInterval = 24 * 60 * 60
    static let limit = 2

    private let file: URL
    private var stamps: [TimeInterval]?
    private(set) var snapshotLimitReached = false

    private struct Record: Codable {
        let version: Int
        let attempts: [TimeInterval]
        let snapshotLimitReached: Bool?
    }

    init(snapshot: String) {
        file = URL(fileURLWithPath: snapshot + ".budget")
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            if record.version == 1, record.attempts.count <= Self.limit,
               record.attempts.allSatisfy({ $0.isFinite && $0 >= 0 }) {
                stamps = record.attempts.sorted()
                snapshotLimitReached = record.snapshotLimitReached == true
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            stamps = []
        } catch {
            // An unreadable or malformed budget can't grant new writes.
        }
    }

    mutating func preventWrites() { stamps = nil }

    mutating func setSnapshotLimitReached(_ value: Bool) throws {
        guard snapshotLimitReached != value, let stamps else { return }
        try write(stamps, limitReached: value)
        snapshotLimitReached = value
    }

    private func write(_ attempts: [TimeInterval], limitReached: Bool) throws {
        let data = try JSONEncoder().encode(Record(version: 1, attempts: attempts,
                                                    snapshotLimitReached: limitReached ? true : nil))
        try data.write(to: file, options: .atomic)
    }

    private func active(at time: TimeInterval) -> [TimeInterval]? {
        stamps?.filter { time - $0 < Self.window }
    }

    func count(at time: TimeInterval) -> Int { active(at: time)?.count ?? Self.limit }

    func next(at time: TimeInterval) -> TimeInterval? {
        guard let current = active(at: time) else { return nil }
        return current.count < Self.limit ? time : current[0] + Self.window
    }

    // Reserve before writing the large file. An interrupted attempt consumes its slot.
    mutating func reserve(at time: TimeInterval) throws -> Bool {
        guard var current = active(at: time), current.count < Self.limit else { return false }
        current.append(time)
        try write(current, limitReached: snapshotLimitReached)
        stamps = current
        return true
    }
}

struct FileUpdate: OptionSet {
    let rawValue: UInt8
    static let structural = Self(rawValue: 1 << 0)
    static let renamed = Self(rawValue: 1 << 1)
}

struct DirectoryUpdate {
    var recursive: Bool?
    var maySkipAfterParent = false
    var files: [String: FileUpdate] = [:]
    var metadata = false
    mutating func requestReconciliation(recursive: Bool, maySkipAfterParent: Bool) {
        if recursive {
            self.maySkipAfterParent = self.recursive == true
                ? self.maySkipAfterParent && maySkipAfterParent : maySkipAfterParent
        }
        self.recursive = self.recursive == true || recursive
        files.removeAll()
    }
}

/// A first content observation is immediate. Further notifications for the
/// same path are combined until 30 seconds after the last observation.
struct FileContentSchedule {
    private static let interval: UInt64 = 30 * ReplayLag.second
    private var visits: [String: UInt64] = [:]
    private var pending: [String: (due: UInt64, events: [Int: UInt64])] = [:]
    private var lastPrune: UInt64 = 0

    var next: UInt64? { pending.values.lazy.map(\.due).min() }
    var count: Int { pending.count }
    var pendingVolumes: Set<Int> { Set(pending.values.flatMap { $0.events.keys }) }

    mutating func enqueue(_ path: String, event: UInt64, volume: Int, now: UInt64) {
        if now - lastPrune >= Self.interval {
            visits = visits.filter { now - $0.value < Self.interval }
            lastPrune = now
        }
        if pending[path] == nil {
            pending[path] = (visits[path].map { max(now, $0 + Self.interval) } ?? now, [:])
        }
        let earlier = pending[path]?.events[volume] ?? .max
        pending[path]?.events[volume] = min(earlier, event)
    }

    mutating func take(at now: UInt64, force: Bool) -> [String] {
        let ready = pending.compactMap { force || $0.value.due <= now ? $0.key : nil }
        for path in ready { observed(path, at: now) }
        return ready
    }

    mutating func observed(_ path: String, at now: UInt64) {
        pending.removeValue(forKey: path)
        visits[path] = now
    }

    func floors() -> [Int: UInt64] {
        var result: [Int: UInt64] = [:]
        for item in pending.values {
            for (volume, event) in item.events { result[volume] = min(result[volume] ?? .max, event) }
        }
        return result
    }

    mutating func discard(volumes: Set<Int>) {
        pending = pending.filter { volumes.isDisjoint(with: $0.value.events.keys) }
    }
}
