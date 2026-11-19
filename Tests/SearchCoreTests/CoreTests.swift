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

    @Test func packedNameVerificationRetainsExactPagedOrder() {
        var index = SearchIndex()
        let root = index.append("/test", attribute: Kind.anchor)
        for i in 0..<2_100 {
            index.append("00-unrelated-\(i)", parent: root)
            index.append("zz-unrelated-\(i)", parent: root)
        }
        for i in 0..<720 {
            let key = (i * 347) % 720
            let flags = key.isMultiple(of: 10) ? Kind.file | Kind.hidden : Kind.file
            index.append("\(key + 1_000)-AbCdEfGh12345678IJkLmNö.txt", parent: root, attribute: flags)
            index.append("\(key + 1_000)-AbCdEfGh123X5678IJkLmNö.md", parent: root)
        }
        index.prepare()
        for direction in SearchDirection.allCases {
            for term in ["abcdefgh", "abcdefgh12345678", "abcdefgh12345678i", "abcdefgh12345678ijklmnö",
                         "abcdefgh txt"] {
                let expected = index.directSearch(term, direction: direction, kind: .document, offset: 75, limit: 200)
                #expect(expected.count == 200)
                #expect(index.search(term, direction: direction, kind: .document, offset: 75, limit: 200) == expected)
            }
        }
    }

    @Test func denseNameQueryKeepsMatchesWhenSparseBufferFills() {
        var index = SearchIndex()
        let root = index.append("/test", attribute: Kind.anchor)
        for i in 0..<2_100 { index.append("unrelated-\(i)", parent: root, size: -1) }
        for i in 0..<4_105 {
            index.append("z-CommonRepeatedCommon-\(i).txt", parent: root, size: Int64(i % 11))
        }
        index.append("z-CommonRepeatedCommon-Cafe\u{301}.txt", parent: root, size: 11)
        index.prepare()
        for column in [SearchColumn.name, .size] {
            let expected = index.directSearch("common txt", column: column, offset: 3_990, limit: 201)
            #expect(expected.count == 116)
            #expect(index.search("common txt", column: column, offset: 3_990, limit: 201) == expected)
        }
    }

    @Test func slashBranchProbePreservesLeafAnchorsAndLongStems() {
        var index = SearchIndex()
        let anchor = index.append("/root", attribute: Kind.anchor)
        let parts = (0..<9).map { String(repeating: "x", count: 30) + String($0) }
        var directory = anchor
        for part in parts {
            directory = index.append(part, parent: directory, attribute: Kind.directory)
        }
        index.append("target.txt", parent: directory)
        index.append("target-later.txt", parent: directory, size: 100)
        index.prepare()
        let long = "/" + parts.joined(separator: "/") + "/tar"
        for query in [long, "/missing/target", "/root/ target", "/root/ missing"] {
            #expect(index.search(query, mode: .path) == index.directSearch(query, mode: .path))
        }
        #expect(index.search(long, mode: .path).count == 2)
        #expect(index.search(long, mode: .path, column: .size, direction: .descending, limit: 1).map(\.name)
            == ["target-later.txt"])
        let previous = index.prepared
        let bytes = index.names.count
        index.prepared = nil
        index.append("/leaf-root/partial.txt")
        index.prepare(extending: previous, previousNameBytes: bytes)
        #expect(index.search("/leaf-root/par", mode: .path).map(\.name) == ["/leaf-root/partial.txt"])
    }

    @Test func slashOrderedPrefixPreservesFilteringAndOffsets() {
        var index = SearchIndex()
        let root = index.append("/fixture", attribute: Kind.anchor)
        let located = index.append("branch", parent: root, attribute: Kind.directory)
        var suppressed: [UInt32] = []
        for i in 0..<100 {
            let row = index.append("a-\(i).txt", parent: located,
                                   attribute: i.isMultiple(of: 5) ? Kind.file | Kind.hidden : Kind.file)
            if i.isMultiple(of: 7) { suppressed.append(row) }
        }
        for i in 0..<50_000 { index.append("z-\(i).md", parent: root) }
        for row in suppressed { index.setSuppressed(Int(row), true) }
        index.prepare()
        let direct = index.directSearch("/fixture/branch/a", mode: .path, kind: .document, offset: 9, limit: 18)
        #expect(direct.count == 18)
        #expect(index.search("/fixture/branch/a", mode: .path, kind: .document, offset: 9, limit: 18) == direct)
    }

    @Test func splitSlashPassReconstructsParentsFromEarlierRows() {
        var index = SearchIndex()
        index.reserve(1_500_010, nameBytes: 9_000_100)
        let root = index.append("/fixture", attribute: Kind.anchor)
        let earlier = index.append("branch", parent: root, attribute: Kind.directory)
        index.append("first.txt", parent: earlier)
        let noise = Array("blank".utf8)
        noise.withUnsafeBufferPointer { bytes in
            for _ in 0..<1_500_000 {
                index.append(bytes: bytes, parent: root, size: 0, modified: 0, attribute: Kind.file)
            }
        }
        let later = index.append("subdir", parent: earlier, attribute: Kind.directory)
        index.append("last.txt", parent: later)
        index.prepare()
        let rows = index.search("/fixture/branch/", mode: .path, kind: .document, limit: 600)
        #expect(rows.map(\.name) == ["first.txt", "last.txt"])
    }

    @Test func pathRenderingJoinsRawComponentsWithUTF8Repair() {
        var index = SearchIndex()
        let root = index.append("/", attribute: Kind.anchor)
        let directory = index.append("Cafe\u{301}", parent: root, attribute: Kind.directory)
        let bytes: [UInt8] = [0x66, 0xff, 0x80, 0x6f]
        let leaf = bytes.withUnsafeBufferPointer {
            index.append(bytes: $0, parent: directory, size: 0, modified: 0, attribute: Kind.file)
        }
        #expect(index.fullPath(root) == "/")
        #expect(index.fullPath(directory) == "/" + index.name(directory))
        let expected = "/" + index.name(directory) + "/" + index.name(leaf)
        #expect(index.fullPath(leaf).utf8.elementsEqual(expected.utf8))
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
