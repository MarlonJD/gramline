import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue { if case .object(let o) = self { o[key] ?? .null } else { .null } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var boolean: Bool { if case .bool(let b) = self { b } else { false } }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
}

public struct WireFrame: Codable, Sendable {
    public let v: Int
    public let id: String?
    public let type: String
    public let data: JSONValue?
    public let error: CoreError?
    public init(id: String? = nil, type: String, data: JSONValue = .object([:])) {
        self.v = 1; self.id = id; self.type = type; self.data = data; self.error = nil
    }
}

public struct CoreError: Codable, Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// Bounded framing handles partial reads and multiple messages per pipe read.
public struct LineFramer: Sendable {
    public static let maximumSize = 16 * 1024 * 1024
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= Self.maximumSize else { throw oversized() }
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= Self.maximumSize else { throw oversized() }
        return lines
    }
    private func oversized() -> CoreError { CoreError(code: "protocol", message: "The connection helper returned an oversized frame.") }
}
