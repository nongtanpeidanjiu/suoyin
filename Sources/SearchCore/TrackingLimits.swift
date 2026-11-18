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
            baseline = points.removeFirst().event
        }
        if let last = points.last, last.time / Self.second == time / Self.second {
            points.removeLast()
        }
        points.append((time, event))
    }

    func position(at time: UInt64, observed: UInt64?, pending: UInt64?) -> UInt64? {
        guard let observed else { return nil }
        let aged = time >= Self.margin
            ? points.last(where: { $0.time <= time - Self.margin })?.event : nil
        guard let safe = aged ?? baseline else { return nil }
        let limit = min(observed, safe, pending.map { $0 > 0 ? $0 - 1 : 0 } ?? .max)
        return limit == 0 ? nil : limit
    }
}

struct BaseWriteBudget {
    static let window: TimeInterval = 24 * 60 * 60
    static let limit = 2

    private let file: URL
    private var stamps: [TimeInterval]?

    private struct Record: Codable {
        let version: Int
        let attempts: [TimeInterval]
    }

    init(snapshot: String) {
        file = URL(fileURLWithPath: snapshot + ".budget")
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            if record.version == 1, record.attempts.count <= Self.limit,
               record.attempts.allSatisfy({ $0.isFinite && $0 >= 0 }) {
                stamps = record.attempts.sorted()
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            stamps = []
        } catch {
            // An unreadable or malformed budget can't grant new writes.
        }
    }

    mutating func preventWrites() { stamps = nil }

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
        let data = try JSONEncoder().encode(Record(version: 1, attempts: current))
        try data.write(to: file, options: .atomic)
        stamps = current
        return true
    }
}

struct DirectoryUpdate {
    var recursive: Bool?
    var files: [String: Bool] = [:]
    var metadata = false
    var pending: [Int: UInt64] = [:]

    mutating func add(event: UInt64, volume: Int) {
        pending[volume] = min(pending[volume] ?? .max, event)
    }

    mutating func merge(_ other: DirectoryUpdate) {
        if let recursive = other.recursive { self.recursive = self.recursive == true || recursive }
        if recursive == nil { files.merge(other.files) { $0 || $1 }; metadata = metadata || other.metadata }
        else { files.removeAll() }
        for (volume, event) in other.pending { add(event: event, volume: volume) }
    }
}

struct DirectorySchedule {
    private static let second = ReplayLag.second
    private static let quiet = 60 * second
    private struct Visit {
        let time: UInt64
        let interval: UInt64
        let hidden: Bool
    }
    private struct Pending {
        var update: DirectoryUpdate
        let due: UInt64
        let interval: UInt64
        let hidden: Bool
    }
    private var visits: [String: Visit] = [:]
    private var pending: [String: Pending] = [:]
    private var lastPrune: UInt64 = 0

    var count: Int { pending.count }
    var next: UInt64? { pending.values.lazy.map(\.due).min() }
    var pendingVolumes: Set<Int> { Set(pending.values.flatMap { $0.update.pending.keys }) }
    var pendingItems: Int { pending.values.reduce(0) { $0 + max(1, $1.update.files.count) } }

    func floors() -> [Int: UInt64] {
        var result: [Int: UInt64] = [:]
        for work in pending.values {
            for (volume, event) in work.update.pending {
                result[volume] = min(result[volume] ?? .max, event)
            }
        }
        return result
    }

    func knownVisibility(at path: String, now: UInt64) -> Bool? {
        pending[path]?.hidden ?? visits[path].flatMap { now - $0.time < Self.quiet ? $0.hidden : nil }
    }

    mutating func enqueue(_ update: DirectoryUpdate, at path: String, hidden: Bool, now: UInt64) {
        if now - lastPrune >= Self.quiet {
            visits = visits.filter { now - $0.value.time < Self.quiet }
            lastPrune = now
        }
        if pending[path] != nil {
            pending[path]?.update.merge(update)
            return
        }
        let last = visits[path].flatMap { now - $0.time < Self.quiet ? $0 : nil }
        let interval = hidden ? 30 * Self.second : last.map {
            if $0.interval == 0, now - $0.time >= 5 * Self.second { return 0 }
            return min(30 * Self.second, max(5 * Self.second, $0.interval * 2))
        } ?? 0
        let due = last.map { max(now, $0.time + interval) } ?? now
        pending[path] = Pending(update: update, due: due, interval: interval, hidden: hidden)
    }

    mutating func take(at time: UInt64, force: Bool) -> [String: DirectoryUpdate] {
        var ready: [String: DirectoryUpdate] = [:]
        for path in pending.keys.filter({ force || pending[$0]!.due <= time }) {
            guard let task = pending.removeValue(forKey: path) else { continue }
            ready[path] = task.update
            if !force { visits[path] = Visit(time: time, interval: task.interval, hidden: task.hidden) }
        }
        return ready
    }

    mutating func discard(volumes: Set<Int>) {
        pending = pending.filter { volumes.isDisjoint(with: $0.value.update.pending.keys) }
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
