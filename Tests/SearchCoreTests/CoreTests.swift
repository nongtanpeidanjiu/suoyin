import Foundation
import Testing
@testable import SearchCore

@Suite(.serialized)
struct CoreTests {
    private func fixture() -> SearchIndex {
        var index = SearchIndex()
        let root = index.append("/", attribute: Kind.anchor)
        let folder = index.append("质量文件夹", parent: root, size: 0, modified: 8, attribute: Kind.directory)
        index.append("路径-2026.PDF", parent: folder, size: 39, modified: 7)
        index.append("公司路径-2026.pdf", parent: folder, size: 15, modified: 7)
        index.append("Cafe\u{301}.txt", parent: root, size: 1, modified: 6)
        index.append(".hidden.txt", parent: root, size: 40, modified: 4, attribute: Kind.file | Kind.hidden)
        index.append(".Trash", parent: root, attribute: Kind.directory | Kind.excluded)
        return index
    }

    @Test func nameMatchingAndVisibility() {
        var index = fixture()
        index.prepare()
        #expect(index.search("PDF  2026").count == 2)
        #expect(index.search("Café").map(\.name) == ["Cafe\u{301}.txt"])
        #expect(index.search("quality").isEmpty)
        #expect(index.search("hidden").isEmpty)
        #expect(index.search("hidden", showAll: true).count == 1)
        #expect(index.search(".Trash", showAll: true).isEmpty)
    }

    @Test func allPathWordsMustMatchContinuously() {
        var index = fixture()
        index.prepare()
        #expect(index.search("质量 2026", mode: .path).count == 2)
        #expect(index.search("质量文件夹/路径", mode: .path).map(\.name) == ["路径-2026.PDF"])
        #expect(index.search("质量文件夹/", mode: .path).count == 2)
        #expect(index.search("/质量文件夹", mode: .path).count == 3)
        #expect(index.search("质量 nonexistent", mode: .path).isEmpty)
    }

    @Test func fourColumnsAgreeWithDirectSelectionForSubsequentPages() {
        var index = fixture()
        index.prepare()
        for column in SearchColumn.allCases {
            for direction in SearchDirection.allCases {
                for offset in [0, 2] {
                    let rows = index.search("", column: column, direction: direction, showAll: true, offset: offset, limit: 2)
                    let reference = index.directSearch("", column: column, direction: direction, showAll: true, offset: offset, limit: 2)
                    #expect(rows == reference)
                }
            }
        }
    }

    @Test func sparseNameSelectionPreservesVisibilityTypesOrderAndOffsets() {
        var index = SearchIndex()
        let root = index.append("/", attribute: Kind.anchor)
        for i in 0..<3_000 { index.append("aaa-\(i).txt", parent: root) }
        index.append("zz-Cafe\u{301}.txt", parent: root)
        index.append("zz-Café.txt", parent: root)
        index.append("zz-Café.pdf", parent: root)
        index.append("zz-Café.png", parent: root)
        index.append(".zz-Café.png", parent: root, attribute: Kind.file | Kind.hidden)
        let suppressed = index.append("zz-Café-removed.txt", parent: root)
        index.setSuppressed(Int(suppressed), true)
        index.prepare()
        for direction in SearchDirection.allCases {
            for showAll in [false, true] {
                for kind in [EngineKind.any, .document, .image] {
                    for offset in [0, 1, 4] {
                        #expect(index.search("zz café", direction: direction, showAll: showAll, kind: kind,
                                             offset: offset, limit: 2) ==
                                index.directSearch("zz café", direction: direction, showAll: showAll, kind: kind,
                                                   offset: offset, limit: 2))
                    }
                }
            }
        }
    }

    @Test func nameFilterHandlesBoundariesAndAppendOnlyViews() throws {
        var index = SearchIndex()
        let root = index.append("/test", attribute: Kind.anchor)
        let parent = index.append("Café archipelago", parent: root, attribute: Kind.directory)
        for i in 0..<4_500 { index.append("filler-row-\(i).txt", parent: parent) }
        let padding = (4096 - (index.names.count % 4096) + 4094) % 4096
        index.append(String(repeating: "x", count: padding) + "BoundaryProbe.PDF", parent: parent)
        index.prepare()
        let prior = try #require(index.prepared)
        #expect(!prior.nameFilter.isEmpty)
        let bytes = index.names.count
        index.prepared = nil
        index.append("Earlier boundaryprobe.txt", parent: parent)
        index.append("decomposed Cafe\u{301} needle.txt", parent: parent, attribute: Kind.file | Kind.hidden)
        index.append("z-last rare-needle.md", parent: parent)
        var reference = index
        reference.prepare()
        index.prepare(extending: prior, previousNameBytes: bytes)
        #expect(index.prepared?.nameFilter == reference.prepared?.nameFilter)
        #expect(index.prepared?.nameOrder == reference.prepared?.nameOrder)
        for mode in [QueryMode.name, .path] {
            for kind in [EngineKind.any, .document, .image] {
                for term in ["boundaryprobe", "café needle", "archipelago needle", "unlikely absence"] {
                    let direct = index.directSearch(term, mode: mode, showAll: true, kind: kind)
                    #expect(index.search(term, mode: mode, showAll: true, kind: kind) == direct)
                }
            }
        }
    }

    @Test func normalizationStoresOnlyChangedNonASCIIKeys() {
        var index = SearchIndex()
        let root = index.append("/UPPER", attribute: Kind.anchor)
        let folder = index.append("MixedÉ", parent: root, attribute: Kind.directory)
        index.append("REPORT [Name].PDF", parent: folder)
        index.append("REPORT {Name}.PDF", parent: folder)
        index.append("CAFE\u{301}.PDF", parent: folder)
        index.append("Report-é.PDF", parent: folder)
        index.prepare()
        #expect(index.prepared?.changedRows == [4])
        for column in SearchColumn.allCases {
            for (term, mode) in [("report  [name]", QueryMode.name), ("café", .name),
                                 ("report É", .name), ("upper/mixedÉ/report P", .path),
                                 ("XEDÉ/CAfÉ", .path), ("REPORT\u{301}", .name)] {
                #expect(index.search(term, mode: mode, column: column) ==
                        index.directSearch(term, mode: mode, column: column))
            }
        }
        #expect(index.search("report é").map(\.name) == ["Report-é.PDF"])
        #expect(index.search("report É").isEmpty)
    }

    @Test func secondaryOrdersAreBuiltSeparatelyAndExpire() throws {
        var index = fixture()
        index.prepare()
        let cache = try #require(index.prepared?.columnOrders)
        #expect(cache.bytes == 0)
        for column in [SearchColumn.size, .modified, .path] {
            #expect(index.search("", column: column) == index.directSearch("", column: column))
            #expect(cache.bytes > 0)
            let now = DispatchTime.now().uptimeNanoseconds
            cache.expire(column, at: now + 298_000_000_000)
            #expect(cache.bytes > 0)
            cache.expire(column, at: now + 300_000_000_000)
            #expect(cache.bytes == 0)
        }
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".m2-tmp", isDirectory: true)
            .appendingPathComponent("test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func snapshotRoundtripAndRecovery() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("index.snapshot")
        let source = fixture()
        try source.save(to: file.path)
        let restored = try SearchIndex.load(from: file.path)
        #expect(restored.search("") == source.search(""))
        let valid = try Data(contentsOf: file)
        var corrupt = valid
        corrupt[corrupt.count - 3] ^= 0x42
        for data in [corrupt, Data(valid.dropLast())] {
            try data.write(to: file)
            #expect(throws: SnapshotError.self) { try SearchIndex.load(from: file.path) }
            var rebuilt = false
            let recovered = try SearchIndex.loadOrRebuild(from: file.path) {
                rebuilt = true
                return source
            }
            #expect(rebuilt)
            #expect(recovered.search("质量 2026", mode: .path).count == 2)
            #expect(try SearchIndex.load(from: file.path).search("") == source.search(""))
        }
    }

    @Test func bulkAndOrdinaryReadSameMetadataAndDoNotFollowLinks() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appendingPathComponent("样本", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: child.appendingPathComponent("Name.bin"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Symbolic"), withDestinationURL: child)
        var phases: [ScanMark] = []
        let bulk = try SearchIndex.scan(root: folder.path, workers: 2) { mark, _ in phases.append(mark) }
        let ordinary = try SearchIndex.scan(root: folder.path, workers: 1, ordinary: true)
        func byPath(_ index: SearchIndex) -> [String: [Int64]] {
            Dictionary(uniqueKeysWithValues: index.search("", showAll: true).map { ($0.path, [$0.size, $0.modified]) })
        }
        #expect(phases.prefix(2).map(\.phase) == ["listener_ready", "scan_start"])
        #expect(phases.first?.listenerCount == 1)
        #expect(byPath(bulk).count == 3)
        #expect(byPath(bulk) == byPath(ordinary))
    }
}
