import Foundation

enum ConfigProfileStatus: Codable, Sendable, Hashable {
    case clean
    case modified(Int)
    case missing(Int)
    case empty
    case unknown

    var displayName: String {
        switch self {
        case .clean:
            "Clean"
        case .modified(let count):
            count == 1 ? "1 modified" : "\(count) modified"
        case .missing(let count):
            count == 1 ? "1 missing" : "\(count) missing"
        case .empty:
            "Empty"
        case .unknown:
            "Unknown"
        }
    }

    var isClean: Bool {
        if case .clean = self { return true }
        return false
    }
}
