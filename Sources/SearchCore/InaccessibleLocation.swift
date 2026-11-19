import Darwin
import Foundation

public struct InaccessibleLocation: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case likelyNeedsFullDiskAccess
        case filePermissions
        case unknown
    }

    public let path: String
    public let count: Int
    public let reason: Reason
}

struct AccessDenials {
    let privacyRoots: [String]

    init(home: String) {
        privacyRoots = [
            "Desktop", "Documents", "Downloads", "Library/Mail", "Library/Messages",
            "Library/Safari", "Library/Mobile Documents/com~apple~CloudDocs"
        ].map { joinedPath(home, $0) }
    }

    func reason(at path: String, error: Int32?, missingFullDiskAccess: Bool) -> InaccessibleLocation.Reason {
        if error == EACCES { return .filePermissions }
        guard error == EPERM, missingFullDiskAccess else { return .unknown }
        let logical = path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
        return privacyRoots.contains(where: { inside(logical, $0) }) ? .likelyNeedsFullDiskAccess : .unknown
    }

    static func summarize(_ raw: [InaccessibleLocation]) -> [InaccessibleLocation] {
        func collapseDescendants(_ counts: [String: Int]) -> [String: Int] {
            counts.reduce(into: [:]) { result, entry in
                var representative = entry.key
                var ancestor = entry.key
                while ancestor != "/" {
                    ancestor = parentPath(ancestor)
                    if counts[ancestor] != nil { representative = ancestor }
                }
                result[representative, default: 0] += entry.value
            }
        }

        var result: [InaccessibleLocation] = []
        for (reason, locations) in Dictionary(grouping: raw, by: \.reason) {
            let counts = locations.reduce(into: [String: Int]()) { $0[$1.path, default: 0] += $1.count }
            let top = collapseDescendants(counts)
            let siblingGroups = Dictionary(grouping: top.keys, by: parentPath)
            let grouped = siblingGroups.reduce(into: [String: Int]()) { result, group in
                let representative = group.value.count > 1 ? group.key : group.value[0]
                result[representative, default: 0] += group.value.reduce(0) { $0 + (top[$1] ?? 0) }
            }
            result += collapseDescendants(grouped).map {
                InaccessibleLocation(path: $0.key, count: $0.value, reason: reason)
            }
        }
        return result.sorted { lhs, rhs in
            lhs.path == rhs.path ? lhs.reason.rawValue < rhs.reason.rawValue : lhs.path < rhs.path
        }
    }
}
