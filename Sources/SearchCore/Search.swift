import Darwin
import DarwinMetadata
import Foundation

/// Shared by published copies of the same immutable base records.
final class ColumnOrders {
    private static let idle: UInt64 = 300_000_000_000
    private let lock = NSLock()
    private var cached: [SearchColumn: (rows: [UInt32], lastUse: UInt64)] = [:]

    var bytes: Int {
        lock.withLock { cached.values.reduce(0) { $0 + 4 * $1.rows.capacity } }
    }

    func order(for column: SearchColumn, build: () -> [UInt32]?) -> [UInt32]? {
        lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            if let hit = cached[column], now - hit.lastUse < Self.idle {
                cached[column]?.lastUse = now
                return hit.rows
            }
            let needsWake = cached[column] == nil
            guard let rows = build() else { return nil }
            let finished = DispatchTime.now().uptimeNanoseconds
            cached[column] = (rows, finished)
            if needsWake { scheduleExpiry(column, at: finished + Self.idle) }
            return rows
        }
    }

    private func scheduleExpiry(_ column: SearchColumn, at deadline: UInt64) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
            self?.expire(column, at: DispatchTime.now().uptimeNanoseconds)
        }
    }

    func expire(_ column: SearchColumn, at now: UInt64) {
        lock.withLock {
            guard let lastUse = cached[column]?.lastUse else { return }
            let expiry = lastUse + Self.idle
            if now >= expiry { cached.removeValue(forKey: column) }
            else { scheduleExpiry(column, at: expiry) }
        }
    }
}

struct PreparedSearch {
    var keyBytes: [UInt8] = []
    var keyOffsets: [UInt32]
    var changedRows: [UInt32] = []
    var nameOrder: [UInt32] = []
    let columnOrders = ColumnOrders()

    init(keyOffsets: [UInt32]) { self.keyOffsets = keyOffsets }

    init(index: SearchIndex) {
        keyOffsets = [UInt32](repeating: .max, count: index.recordCount)
        index.names.withUnsafeBufferPointer { pool in
            for (i, record) in index.records.enumerated() {
                let offset = Int(record.offset)
                let end = i + 1 == index.recordCount ? pool.count : Int(index.records[i + 1].offset)
                let base = pool.baseAddress!.advanced(by: offset)
                let count = end - offset - 1
                guard dm_has_non_ascii(base, count) else { continue }
                let original = UnsafeBufferPointer(start: base, count: count)
                let normalized = String(decoding: original, as: UTF8.self).precomposedStringWithCanonicalMapping
                guard !normalized.utf8.elementsEqual(original) else { continue }
                keyOffsets[i] = UInt32(keyBytes.count)
                changedRows.append(UInt32(i))
                keyBytes.append(contentsOf: normalized.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 })
                keyBytes.append(0)
            }
        }
    }

    func withView<T>(index: SearchIndex, _ body: (inout DMQueryView) -> T) -> T {
        index.records.withUnsafeBufferPointer { rows in
            index.attributes.withUnsafeBufferPointer { attributes in
                index.names.withUnsafeBufferPointer { names in
                    keyBytes.withUnsafeBufferPointer { folded in
                        keyOffsets.withUnsafeBufferPointer { offsets in
                            changedRows.withUnsafeBufferPointer { changed in
                                index.suppressed.withUnsafeBufferPointer { suppressed in
                                    var view = DMQueryView(rows: rows.baseAddress,
                                        attributes: attributes.baseAddress, names: names.baseAddress,
                                        folded_names: folded.baseAddress, fold_offsets: offsets.baseAddress,
                                        fold_rows: changed.baseAddress,
                                        suppressed_rows: suppressed.isEmpty ? nil : suppressed.baseAddress,
                                        row_count: rows.count, name_bytes: names.count,
                                        fold_bytes: folded.count, fold_count: changed.count)
                                    return body(&view)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func order(for column: SearchColumn, index: SearchIndex) -> [UInt32]? {
        if column == .name { return nameOrder }
        return columnOrders.order(for: column) {
            let number: Int32
            switch column {
            case .path: number = 1
            case .size: number = 2
            case .modified: number = 3
            case .name: return nameOrder
            }
            var rows = nameOrder
            let ok = withView(index: index) { view in
                rows.withUnsafeMutableBufferPointer { dm_column_order(&view, $0.baseAddress, number) }
            }
            return ok ? rows : nil
        }
    }
}

private extension Array {
    mutating func removeSpareCapacity() {
        guard capacity - count > 64 else { return }
        self = withUnsafeBufferPointer { Array($0) }
    }
}

extension SearchIndex {
    func storageBreakdown() -> [String: Int] {
        let keyBytes = prepared.map { $0.keyBytes.capacity + 4 * ($0.keyOffsets.capacity + $0.changedRows.capacity) } ?? 0
        let order = prepared.map {
            4 * $0.nameOrder.capacity + $0.columnOrders.bytes
        } ?? 0
        return [
            "recordsAndAttributes": records.capacity * MemoryLayout<DMRecord>.stride + attributes.capacity,
            "names": names.capacity, "foldedKeys": keyBytes, "sortTables": order,
            "suppressedRows": suppressed.capacity,
        ]
    }

    mutating func tightenScannedStorage() {
        records.removeSpareCapacity()
        attributes.removeSpareCapacity()
        names.removeSpareCapacity()
        prepare()
        prepared?.keyBytes.removeSpareCapacity()
        prepared?.keyOffsets.removeSpareCapacity()
        prepared?.changedRows.removeSpareCapacity()
        prepared?.nameOrder.removeSpareCapacity()
    }

    /// Materialize the normalized keys and the default name order.
    public mutating func prepare() {
        guard prepared == nil, !records.isEmpty else { return }
        var keys = PreparedSearch(index: self)
        var names = [UInt32](repeating: 0, count: recordCount)
        keys.withView(index: self) { view in
            names.withUnsafeMutableBufferPointer { dm_name_order(&view, $0.baseAddress) }
        }
        keys.nameOrder = names
        prepared = keys
    }

    public func search(_ query: String, mode: QueryMode = .name, column: SearchColumn = .name,
                       direction: SearchDirection = .ascending, showAll: Bool = false,
                       offset: Int = 0, limit: Int = 50) -> [SearchRow] {
        guard let capacity = pageCapacity(offset: offset, limit: limit),
              !query.utf8.contains(0) else { return [] }
        guard let prepared, let order = prepared.order(for: column, index: self) else {
            return directSearch(query, mode: mode, column: column, direction: direction,
                                showAll: showAll, offset: offset, limit: limit)
        }
        var words: [UInt8] = []
        var offsets: [UInt32] = []
        for word in Self.queryWords(query) {
            offsets.append(UInt32(words.count))
            words.append(contentsOf: word)
            words.append(0)
        }
        let length = capacity - offset
        var ids = [UInt32](repeating: 0, count: length)
        let emitted = prepared.withView(index: self) { view in
            order.withUnsafeBufferPointer { order in
                words.withUnsafeBufferPointer { words in
                    offsets.withUnsafeBufferPointer { offsets in
                        ids.withUnsafeMutableBufferPointer { ids in
                            dm_query(&view, order.baseAddress, words.baseAddress, offsets.baseAddress,
                                     offsets.count, mode == .path, direction == .descending,
                                     showAll, offset, ids.count, ids.baseAddress)
                        }
                    }
                }
            }
        }
        guard emitted >= 0 && emitted <= length else {
            return directSearch(query, mode: mode, column: column, direction: direction,
                                showAll: showAll, offset: offset, limit: limit)
        }
        return ids.prefix(emitted).map { row($0) }
    }
}
