import Darwin
import Foundation

struct ContainerAccess {
    let roots: [String]
    let hasFullDiskAccess: () -> Bool

    init(home: String, probe: (() -> Bool)? = nil) {
        let library = joinedPath(home, "Library")
        roots = ["Containers", "Group Containers"].map { joinedPath(library, $0) }
        hasFullDiskAccess = probe ?? {
            // Full Disk Access is granted through System Settings. This
            // preflight opens the file without reading any database contents.
            let path = joinedPath(library, "Application Support/com.apple.TCC/TCC.db")
            var fd: Int32
            repeat { fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            while fd < 0 && errno == EINTR
            guard fd >= 0 else { return false }
            _ = Darwin.close(fd)
            return true
        }
    }

    func paths(includeDataAliases: Bool) -> [String] {
        includeDataAliases ? roots + roots.map { dataRoot + $0 } : roots
    }
}
