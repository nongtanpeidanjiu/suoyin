import Darwin
import Foundation
import Quartz
import UniformTypeIdentifiers

/// A file Quick Look shows under the original file's name.
final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL!
    let previewItemTitle: String!

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
        super.init()
    }
}

/// Lets Quick Look show the contents of text files it has no preview for.
///
/// Quick Look falls back to a large icon for text it does not know, such as
/// Markdown, YAML or `.ini`. For those, the preview is given a stand-in in
/// the app's caches folder, named like a `.txt` file: an APFS clone of the
/// original (it shares the original's storage, so nothing is copied), or,
/// when cloning is not possible, the file is large, or its text is in the
/// GB 18030 family of Chinese encodings (so it reads right whatever the
/// system language), the first 2 MB re-encoded as UTF-8. Markdown becomes a rendered page instead.
/// Quick Look does not follow symbolic links: it shows the link itself.
/// The original file is only ever read, and only its first 64 KB unless the
/// stand-in needs more.
final class PreviewContent {
    /// What to give Quick Look for one file.
    enum Plan: Equatable {
        /// The file itself: Quick Look has its own preview, or the file has
        /// no text to show.
        case original
        /// A stand-in file in the caches folder.
        case standIn(URL)
    }

    static let probeLength = 64 * 1024
    /// GB 18030 text is converted up to this much; the rest is left out.
    static let convertLimit = 2 * 1024 * 1024
    /// Larger Markdown is shown as plain text.
    static let markdownLimit = 512 * 1024

    let root: URL
    private let queue = DispatchQueue(label: "dev.local.filesearch.preview-content", qos: .userInitiated)
    private let lock = NSLock()
    /// Bumped for every new request; work for an older one is dropped.
    private var latest = 0
    /// Results for files looked at while the preview is open, newest last.
    private var plans: [(path: String, plan: Plan)] = []

    /// `~/Library/Caches/<bundle identifier>/PreviewStandIns`.
    static let standInsFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let owner = Bundle.main.bundleIdentifier ?? "dev.local.filesearch"
        return caches.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("PreviewStandIns", isDirectory: true)
    }()

    init() {
        root = Self.standInsFolder
    }

    /// Removes the whole folder at once, before anything can be previewed:
    /// at launch, for stand-ins a crash left behind.
    static func removeAll() {
        try? FileManager.default.removeItem(at: standInsFolder)
    }

    /// The plan for a file already looked at, or nil while it is unknown.
    func plan(for path: String) -> Plan? {
        plans.last { $0.path == path }?.plan
    }

    /// Works out, off the main thread, what to show for `path`, then calls
    /// `done` on the main thread with the plan, unless a newer request came
    /// in meanwhile, in which case its result is discarded. Asking again for
    /// the same file is harmless: only the newest answer is used.
    func prepare(_ path: String, done: @escaping (Plan) -> Void) {
        lock.lock(); latest += 1; let ticket = latest; lock.unlock()
        let root = root
        queue.async { [weak self] in
            let current = { [weak self] () -> Bool in
                guard let self else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.latest == ticket
            }
            let plan = current() ? Self.makePlan(for: path, in: root, stillWanted: current) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let plan else { return }
                guard current() else { Self.discard(plan); return }
                self.remember(path, plan)
                done(plan)
            }
        }
    }

    /// Keeps the current and previous file's stand-ins (Quick Look may
    /// still be fading the previous one out) and removes older ones.
    private func remember(_ path: String, _ plan: Plan) {
        plans.removeAll { $0.path == path }
        plans.append((path, plan))
        while plans.count > 2 { Self.discard(plans.removeFirst().plan) }
    }

    /// Removes every stand-in when the preview closes. Work still under
    /// way is dropped, and anything it writes is removed with the rest, as
    /// this runs after it on the same queue.
    func clear() {
        plans = []
        lock.lock(); latest += 1; lock.unlock()
        let root = root
        queue.async { try? FileManager.default.removeItem(at: root) }
    }

    /// The same, waiting until it is done: when the application quits.
    func clearNow() {
        plans = []
        lock.lock(); latest += 1; lock.unlock()
        let root = root
        queue.sync { try? FileManager.default.removeItem(at: root) }
    }

    private static func discard(_ plan: Plan) {
        // Each stand-in lives in its own folder. A clone is a file of its
        // own: removing it leaves the original untouched.
        guard case .standIn(let url) = plan else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Deciding

    /// Types Quick Look previews well by itself even though they are text,
    /// so a text file of one of these types is left alone.
    private static let nativeText: [UTType] = [
        .plainText, .html, .xml, .json, .propertyList, .rtf, .vCard, .emailMessage,
        UTType("com.apple.ical.ics"), UTType("com.adobe.postscript"),
    ].compactMap { $0 }
    /// Types that are never text, or that Quick Look shows richly whatever
    /// their bytes; the file is not read at all.
    private static let neverText: [UTType] = [
        .image, .pdf, .audio, .movie, .font, .archive, .application,
        .spreadsheet, .presentation, .package, .directory, .symbolicLink, .aliasFile,
    ]

    private static func makePlan(for path: String, in root: URL, stillWanted: () -> Bool) -> Plan {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey, .fileSizeKey])
        // Gone, unreadable or not a plain file: Quick Look's own notice or view.
        guard let values, values.isRegularFile == true else { return .original }
        let type = values.contentType ?? .data
        // `.ts` is TypeScript far more often than a video stream; the bytes tell.
        let mayBeTypeScript = type.conforms(to: .mpeg2TransportStream)
        if !mayBeTypeScript, neverText.contains(where: type.conforms(to:)) { return .original }
        let native = nativeText.contains(where: type.conforms(to:))
        guard let head = readHead(of: url, length: probeLength) else { return .original }
        let whole = (values.fileSize ?? 0) <= head.count
        guard let encoding = textEncoding(of: head, whole: whole) else { return .original }
        // Quick Look's own text view reads UTF-8, UTF-16 and, as tried on a
        // Chinese system, GB 18030 too: leave its own previews alone.
        if native { return .original }
        guard stillWanted() else { return .original }

        let name = url.lastPathComponent
        // The stand-in's name only has to end right; the title shown is the
        // original name. A name near the 255-byte limit gets a short one.
        let base = name.utf8.count > 240 ? "file" : name
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try makePrivateFolder(root)
            try makePrivateFolder(folder)
            if isMarkdown(type, name: name), let page = markdownPage(url, encoding: encoding,
                                                                    size: values.fileSize ?? 0, title: name) {
                let target = folder.appendingPathComponent(base + ".html")
                try writePrivately(Data(page.utf8), to: target)
                return .standIn(target)
            }
            let target = folder.appendingPathComponent(base + ".txt")
            let small = (values.fileSize ?? 0) <= convertLimit
            if encoding == .gb18030 || !small || clonefile(path, target.path, 0) != 0 {
                try writePrivately(Data(converted(url, encoding).utf8), to: target)
            } else {
                // A clone takes the original's permissions; it is a file of its
                // own, so narrowing them leaves the original untouched.
                guard chmod(target.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            }
            return .standIn(target)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return .original
        }
    }

    /// Stand-ins hold the contents of the user's files, so only the user may
    /// read them: folders 0700, files 0600, whatever the umask.
    private static func makePrivateFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing folder, e.g. from an earlier version, is narrowed too.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Creates the file with mode 0600 from the start, never wider.
    private static func writePrivately(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private static func isMarkdown(_ type: UTType, name: String) -> Bool {
        if let markdown = UTType("net.daringfireball.markdown"), type.conforms(to: markdown) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "mkdn"].contains(ext)
    }

    private static func markdownPage(_ url: URL, encoding: String.Encoding, size: Int, title: String) -> String? {
        guard size <= markdownLimit, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = decode(data, encoding) else { return nil }
        return MarkdownPreview.html(from: text, title: title)
    }

    /// The first part of a text file as UTF-8, with a note when cut short.
    private static func converted(_ url: URL, _ encoding: String.Encoding) throws -> String {
        guard let data = readHead(of: url, length: convertLimit + 1) else { throw CocoaError(.fileReadUnknown) }
        let cut = data.count > convertLimit
        let head = cut ? data.prefix(convertLimit) : data
        // Only the first 64 KB were checked; stray bad bytes further on are
        // shown as replacement marks rather than losing the whole preview.
        guard let text = decode(head, encoding, whole: !cut)
                ?? (encoding == .utf8 ? String(decoding: head, as: UTF8.self) : nil) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return cut ? text + "\n\n…（文件较大，仅显示开头部分）\n" : text
    }

    private static func readHead(of url: URL, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: length) ?? Data()
    }

    // MARK: Telling text from other bytes

    /// The encoding the bytes are text in, or nil when they are not text.
    /// `whole` says the bytes are the entire file; otherwise a character cut
    /// in half at the end is not held against them.
    static func textEncoding(of data: Data, whole: Bool) -> String.Encoding? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return decode(data, .utf16, whole: whole).map { looksLikeText($0) ? .utf16 : nil } ?? nil
        }
        guard !bytes.contains(0) else { return nil }
        for encoding in [String.Encoding.utf8, .gb18030] {
            if let text = decode(data, encoding, whole: whole) { return looksLikeText(text) ? encoding : nil }
        }
        return nil
    }

    /// Decodes, allowing up to three bytes of a character cut off at the end.
    private static func decode(_ data: Data, _ encoding: String.Encoding, whole: Bool = false) -> String? {
        let slack = whole ? 0 : min(3, data.count - 1)
        for drop in 0...max(slack, 0) {
            if let text = String(data: data.dropLast(drop), encoding: encoding) { return text }
        }
        return nil
    }

    /// Text has few control characters besides tab, line breaks, form feed
    /// and escape (colour codes in logs).
    private static func looksLikeText(_ text: String) -> Bool {
        var total = 0, control = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar.value < 0x20, ![0x09, 0x0A, 0x0D, 0x0C, 0x1B].contains(scalar.value) { control += 1 }
            if scalar.value == 0xFFFD { control += 1 }
        }
        return total > 0 && control * 100 <= total
    }
}

extension String.Encoding {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}
