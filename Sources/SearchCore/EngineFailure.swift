import Darwin
import Foundation

public struct EngineFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Category: String, Codable, Sendable {
        case dataDirectoryUnavailable, diskRead, indexCorrupt, indexLimitExceeded, other
    }

    public let category: Category
    public let underlyingMessage: String

    public var description: String { underlyingMessage }

    init(_ error: Error, fallback: Category = .other, dataDirectory: String? = nil) {
        if let failure = error as? Self { self = failure; return }
        underlyingMessage = String(describing: error)
        switch error {
        case SnapshotError.invalid, SnapshotError.unsupportedVersion, is DecodingError:
            category = .indexCorrupt
        case SnapshotError.limitExceeded:
            category = .indexLimitExceeded
        case ScanError.metadata(let path, let code):
            let scope = dataDirectory.map { inside(path, $0) } == true ? Category.dataDirectoryUnavailable : .diskRead
            category = Self.category(for: code, fallback: scope)
        case ScanError.listener:
            category = .diskRead
        case SnapshotError.filesystem(let code):
            category = Self.category(for: code, fallback: fallback == .other ? .diskRead : fallback)
        case let error as CocoaError:
            switch error.code {
            case .fileWriteOutOfSpace, .fileWriteNoPermission, .fileWriteVolumeReadOnly, .fileWriteInvalidFileName:
                category = .dataDirectoryUnavailable
            case .fileReadCorruptFile: category = .indexCorrupt
            default:
                category = fallback == .other && error.errorCode >= 256 && error.errorCode < 512 ? .diskRead : fallback
            }
        default:
            let error = error as NSError
            category = error.domain == NSPOSIXErrorDomain
                ? Self.category(for: Int32(clamping: error.code), fallback: fallback) : fallback
        }
    }

    private static func category(for code: Int32, fallback: Category) -> Category {
        switch code {
        case ENOSPC, EDQUOT, EROFS: return .dataDirectoryUnavailable
        case EIO, ENXIO, ETIMEDOUT: return fallback == .dataDirectoryUnavailable ? fallback : .diskRead
        default: return fallback
        }
    }
}
