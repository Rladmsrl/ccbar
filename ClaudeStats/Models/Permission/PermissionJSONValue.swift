import Foundation

/// `Sendable` mirror of arbitrary JSON that comes back from Claude Code's
/// hook payloads. The `[String: Any]` shape `JSONSerialization` returns is
/// not `Sendable`, so we convert into this enum once at the HTTP boundary
/// and pass it through actor boundaries from there.
indirect enum PermissionJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PermissionJSONValue])
    case object([String: PermissionJSONValue])

    static func from(_ object: Any?) -> PermissionJSONValue {
        guard let object else { return .null }
        if object is NSNull { return .null }
        if let value = object as? Bool, isPureBool(object) { return .bool(value) }
        if let value = object as? Int { return .number(Double(value)) }
        if let value = object as? Int64 { return .number(Double(value)) }
        if let value = object as? Double { return .number(value) }
        if let value = object as? NSNumber {
            return .number(value.doubleValue)
        }
        if let value = object as? String { return .string(value) }
        if let value = object as? [Any?] {
            return .array(value.map { PermissionJSONValue.from($0) })
        }
        if let value = object as? [String: Any?] {
            var out: [String: PermissionJSONValue] = [:]
            out.reserveCapacity(value.count)
            for (k, v) in value { out[k] = .from(v) }
            return .object(out)
        }
        return .null
    }

    /// Convert back to a Foundation-compatible object suitable for
    /// `JSONSerialization`.
    var asFoundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.asFoundation)
        case .object(let dict):
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = v.asFoundation }
            return out
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [PermissionJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: PermissionJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

/// `(value as? Bool)` returns true for any NSNumber that holds 0 or 1, which
/// would silently coerce integer fields like `count: 0` into a boolean.
/// CFBoolean's type id is distinct, so we sniff that explicitly.
private func isPureBool(_ object: Any) -> Bool {
    CFGetTypeID(object as CFTypeRef) == CFBooleanGetTypeID()
}
