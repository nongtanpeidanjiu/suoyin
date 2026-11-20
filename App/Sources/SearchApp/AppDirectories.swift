import Foundation

/// Where the application keeps its own files, decided in one place by the
/// bundle identifier.
///
/// The release (`io.github.nongtanpeidanjiu.suoyin`) keeps everything under
/// its own identifier. The preview (`dev.local.filesearch.demo`) and the
/// executable run outside a bundle keep the folders they always used, so
/// an index already built there is not lost: the index in
/// `Application Support/dev.local.filesearch`, the caches under the bundle
/// identifier, or `dev.local.filesearch` without one.
/// `--data-dir` still wins over all of this (see main.swift).
enum AppDirectories {
    static let releaseIdentifier = "io.github.nongtanpeidanjiu.suoyin"
    /// The folder name the preview and unbundled runs have always used.
    static let legacyName = "dev.local.filesearch"

    /// The folder name inside `~/Library/Application Support` for the index.
    static func dataFolderName(bundleIdentifier: String?) -> String {
        bundleIdentifier == releaseIdentifier ? releaseIdentifier : legacyName
    }

    /// The folder name inside `~/Library/Caches`.
    static func cachesFolderName(bundleIdentifier: String?) -> String {
        bundleIdentifier ?? legacyName
    }

    /// `~/Library/Application Support/<data folder name>`; not created here.
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(dataFolderName(bundleIdentifier: Bundle.main.bundleIdentifier),
                                           isDirectory: true)
    }

    /// `~/Library/Caches/<caches folder name>`; not created here.
    static var cachesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(cachesFolderName(bundleIdentifier: Bundle.main.bundleIdentifier),
                                           isDirectory: true)
    }
}
