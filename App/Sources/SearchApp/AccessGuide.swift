import AppKit

/// Detects Full Disk Access. The setup guide (SetupGuide.swift) walks the
/// user through granting it.
enum DiskAccess {
    /// The privacy database is readable only with Full Disk Access, so an
    /// open attempt tells the two states apart without touching user files.
    static var isGranted: Bool {
        // For looking at the not-yet-granted screens in demo mode only.
        if simulatesMissingAccess { return false }
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private static let simulatesMissingAccess = CommandLine.arguments.contains("--demo")
        && CommandLine.arguments.contains("--simulate-no-access")

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
