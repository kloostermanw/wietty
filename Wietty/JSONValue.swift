import Foundation

/// A minimal JSON value used for MCP tool arguments and results.
///
/// The tool router is deliberately independent of the MCP SDK's own value
/// type so it can be unit-tested without importing the transport layer.
/// `MCPServerHost` converts between the SDK's `Value` and this type.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Accessors

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value): return Int(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Convenience subscript for object members; returns nil for non-objects.
    subscript(key: String) -> JSONValue? {
        if case let .object(members) = self { return members[key] }
        return nil
    }

    // MARK: - Foundation bridging

    /// Converts to a Foundation object suitable for `JSONSerialization`.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .array(values): return values.map(\.foundationObject)
        case let .object(members): return members.mapValues(\.foundationObject)
        }
    }

    /// Serializes to a compact, key-sorted JSON string.
    func encodedString() -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: foundationObject,
            options: [.sortedKeys, .fragmentsAllowed]
        )) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Builds a `JSONValue` from a Foundation object (e.g. from
    /// `JSONSerialization`). Unsupported types become `.null`.
    static func from(foundationObject object: Any) -> JSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // Distinguish Bool from numeric NSNumber via the ObjC type code.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let value = number as? Int, Double(value) == number.doubleValue {
                return .int(value)
            }
            return .double(number.doubleValue)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map(JSONValue.from(foundationObject:)))
        case let value as [String: Any]:
            return .object(value.mapValues(JSONValue.from(foundationObject:)))
        default:
            return .null
        }
    }
}
