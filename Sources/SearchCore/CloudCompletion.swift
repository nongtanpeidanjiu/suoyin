import Foundation
import Network

struct CloudRoots {
    let storage: String?
    let iCloud: String?

    init(home: String?) {
        storage = home.map { $0 + "/Library/CloudStorage" }
        iCloud = home.map { $0 + "/Library/Mobile Documents/com~apple~CloudDocs" }
    }

    static func display(for provider: String) -> (name: String, kind: EngineSourceStatus.CloudProviderKind) {
        if provider.hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs") ||
            provider.hasSuffix("/Library/CloudStorage/iCloudDrive") {
            return ("iCloud Drive", .iCloudDrive)
        }
        return (leafName(provider), .fileProvider)
    }

    func provider(containing path: String) -> String? {
        let physical = path.hasPrefix(dataRoot + "/") ? dataRoot : ""
        let logical = path.dropFirst(physical.count)
        if let iCloud, logical == iCloud || logical.hasPrefix(iCloud + "/") { return physical + iCloud }
        guard let storage, logical.hasPrefix(storage + "/") else { return nil }
        let rest = logical.dropFirst(storage.count + 1)
        guard let name = rest.split(separator: "/", maxSplits: 1).first else { return nil }
        guard !name.hasPrefix(".") else { return nil }
        return physical + storage + "/" + name
    }

    func isVisibleRoot(_ path: String) -> Bool {
        path == storage || provider(containing: path) == path
    }

    func isScanBoundary(_ path: String) -> Bool { path == storage || path == iCloud }

    static func matchesProviderRoot(_ path: String) -> Bool {
        let logical = path.hasPrefix(dataRoot + "/") ? path.dropFirst(dataRoot.count) : path[...]
        if logical.hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs") { return true }
        guard logical.contains("/Library/CloudStorage/") else { return false }
        let components = logical.split(separator: "/")
        guard components.count > 3, components.suffix(3).first == "Library",
              components.dropLast().last == "CloudStorage" else { return false }
        return !components.last!.hasPrefix(".")
    }

    func isTrash(_ path: String) -> Bool {
        guard let provider = provider(containing: path) else { return false }
        return inside(path, joinedPath(provider, ".Trash"))
    }
}

public struct CloudCompletionStatus: Codable, Sendable {
    public internal(set) var pending = 0
    public internal(set) var completed = 0
    public internal(set) var recentFailures = 0
    public internal(set) var totalFailures = 0
    public internal(set) var timedOut = 0
    public internal(set) var inFlight = false
    public internal(set) var activeProvider: String?
}

/// All scheduling and publication state is confined to the index writer.
/// Only the filesystem read runs on the utility queue.
final class CloudCompletion {
    struct Timing {
        var timeout: UInt64 = 30_000_000_000
        var spacing: UInt64 = 700_000_000
        var firstRetry: UInt64 = 60_000_000_000
        var maximumRetry: UInt64 = 3_600_000_000_000
    }

    private struct Job {
        var due: UInt64 = 0
        var delay: UInt64 = 0
        var inherited: UInt8
    }

    private struct Call {
        var path: String
        var ticket: UInt64
        var deadline: UInt64
        var valid = true
    }

    typealias Reader = (String, UInt8) throws -> DirectoryObservation
    private let writer: DispatchQueue
    private let io = DispatchQueue(label: "index.cloud-metadata", qos: .utility, autoreleaseFrequency: .workItem)
    private let timing: Timing
    private let read: Reader
    private let roots: CloudRoots
    private let timer: DispatchSourceTimer
    private let monitor: NWPathMonitor?
    private var jobs: [String: Job] = [:]
    private var call: Call?
    private var failures: [UInt64] = []
    private var ticket: UInt64 = 0
    private var eligibleAt: UInt64 = 0
    private var enabled = false
    private var closed = false
    private var online = true
    private var status = CloudCompletionStatus()
    private(set) var selectedProvider: String?
    private(set) var pendingProviders = Set<String>()
    private var providerJobs: [String: Int] = [:]
    var changed: (CloudCompletionStatus) -> Void = { _ in }
    var beforeApply: () -> Void = {}
    var apply: (String, DirectoryObservation) -> Bool = { _, _ in false }

    init(writer: DispatchQueue, roots: CloudRoots, timing: Timing = Timing(),
         monitorNetwork: Bool = true, read: @escaping Reader) {
        self.writer = writer
        self.roots = roots
        self.timing = timing
        self.read = read
        timer = DispatchSource.makeTimerSource(queue: writer)
        monitor = monitorNetwork ? NWPathMonitor() : nil
        timer.setEventHandler { [weak self] in self?.advance() }
        timer.activate()
        monitor?.pathUpdateHandler = { [weak self] path in
            self?.setNetworkAvailable(path.status == .satisfied)
        }
        monitor?.start(queue: writer)
    }

    deinit {
        timer.cancel()
        monitor?.cancel()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value && call != nil { call?.valid = false }
        advance()
    }

    func enqueue(_ path: String, inherited: UInt8) {
        guard !closed, let provider = roots.provider(containing: path), !roots.isTrash(path) else { return }
        if jobs[path] == nil {
            jobs[path] = Job(inherited: inherited)
            providerJobs[provider, default: 0] += 1
        }
        advance()
    }

    func replacePending(_ pending: [String: UInt8]) {
        if call != nil { call?.valid = false }
        jobs = jobs.filter { pending[$0.key] != nil }
        for (path, attributes) in pending where jobs[path] == nil && !roots.isTrash(path) {
            jobs[path] = Job(inherited: attributes)
        }
        recountProviders()
        advance()
    }

    func invalidate(at path: String) {
        guard let active = call, inside(active.path, path) else { return }
        call?.valid = false
    }

    func invalidateListing(at path: String) {
        if call?.path == path { call?.valid = false }
    }

    func discard(at path: String) {
        invalidate(at: path)
        jobs = jobs.filter { !inside($0.key, path) }
        recountProviders()
        advance()
    }

    func discardOnly(_ path: String) {
        if call?.path == path { call?.valid = false }
        removeJob(path)
        advance()
    }

    func retry() {
        for path in Array(jobs.keys) { jobs[path]?.due = 0 }
        advance()
    }

    func stop() {
        closed = true
        if call != nil { call?.valid = false }
        timer.cancel()
        monitor?.cancel()
        publish()
    }

    func setNetworkAvailable(_ value: Bool) {
        let restored = !online && value
        online = value
        if restored { retry() }
        else { advance() }
    }

    private func fail(_ path: String, at now: UInt64, timeout: Bool = false) {
        guard var job = jobs[path] else { return }
        job.delay = job.delay == 0 ? timing.firstRetry : min(timing.maximumRetry, 2 * job.delay)
        job.due = now + job.delay
        jobs[path] = job
        failures.append(now)
        status.totalFailures += 1
        if timeout { status.timedOut += 1 }
    }

    private func recountProviders() {
        providerJobs.removeAll(keepingCapacity: true)
        for path in jobs.keys {
            if let provider = roots.provider(containing: path) { providerJobs[provider, default: 0] += 1 }
        }
    }

    private func removeJob(_ path: String) {
        guard jobs.removeValue(forKey: path) != nil, let provider = roots.provider(containing: path),
              let count = providerJobs[provider] else { return }
        providerJobs[provider] = count == 1 ? nil : count - 1
    }

    private func advance() {
        guard !closed else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let active = call {
            if active.valid && now >= active.deadline {
                call?.valid = false
                fail(active.path, at: now, timeout: true)
            }
            timer.schedule(deadline: call?.valid == true
                ? DispatchTime(uptimeNanoseconds: active.deadline) : .distantFuture)
        } else if enabled, online, let next = jobs.min(by: {
            $0.value.due == $1.value.due ? $0.key < $1.key : $0.value.due < $1.value.due
        }) {
            let due = max(eligibleAt, next.value.due)
            if due > now {
                timer.schedule(deadline: DispatchTime(uptimeNanoseconds: due))
            } else {
                let path = next.key
                let inherited = next.value.inherited
                ticket += 1
                let number = ticket
                let deadline = now + timing.timeout
                call = Call(path: path, ticket: number, deadline: deadline)
                timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
                let read = self.read
                io.async { [weak self] in
                    let result = Result { try read(path, inherited) }
                    let finished = DispatchTime.now().uptimeNanoseconds
                    guard let self else { return }
                    self.writer.async { self.returned(number, result: result, finished: finished) }
                }
            }
        } else {
            timer.schedule(deadline: .distantFuture)
        }
        publish()
    }

    private func returned(_ ticket: UInt64, result: Result<DirectoryObservation, Error>, finished: UInt64) {
        guard let deadline = call?.deadline, call?.ticket == ticket else { return }
        if closed { call = nil; publish(); return }
        call?.deadline = .max
        beforeApply()
        guard let active = call, active.ticket == ticket else { return }
        if active.valid {
            if finished >= deadline {
                fail(active.path, at: finished, timeout: true)
            } else if let observation = try? result.get(), apply(active.path, observation) {
                removeJob(active.path)
                if case .readable = observation { status.completed += 1 }
            } else {
                fail(active.path, at: finished)
            }
        } else if jobs[active.path]?.due == 0 {
            jobs[active.path]?.due = finished
        }
        call = nil
        eligibleAt = finished + timing.spacing
        advance()
    }

    private func publish() {
        let now = DispatchTime.now().uptimeNanoseconds
        failures.removeAll { now - $0 > timing.maximumRetry }
        status.recentFailures = failures.count
        status.pending = jobs.count
        status.inFlight = call != nil
        let activeProvider = call.flatMap { roots.provider(containing: $0.path) }
        status.activeProvider = activeProvider.map(leafName)
        pendingProviders = Set(providerJobs.keys)
        selectedProvider = pendingProviders.isEmpty ? nil : activeProvider ?? pendingProviders.min()
        changed(status)
    }
}
