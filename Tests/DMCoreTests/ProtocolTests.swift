import DMCore
import Foundation
import Testing

struct ProtocolTests {
    @Test func pipeFramingHandlesFragmentedUTF8AndCoalescedFrames() throws {
        var framer = LineFramer()
        let bytes = Data("{\"text\":\"👋\"}\n{\"v\":1}\n".utf8)
        var lines: [Data] = []
        for byte in bytes { lines += try framer.append(Data([byte])) }
        #expect(lines.count == 2)
        #expect(String(decoding: lines[0], as: UTF8.self) == "{\"text\":\"👋\"}")
    }
    @Test func rejectsOversizedUnterminatedFrame() throws {
        var framer = LineFramer()
        #expect(throws: CoreError.self) { try framer.append(Data(repeating: 65, count: LineFramer.maximumSize + 1)) }
    }
    @Test func preservesLargeIdentifiersWithoutFloatingPointRounding() throws {
        let raw = Data("{\"value\":9223372036854775806}".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: raw)
        #expect(value["value"] == .integer(9223372036854775806))
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }
    @Test func generatedClientIDsArePositive64BitIntegers() {
        let ids = Set((0..<1000).map { _ in Message.newClientID() })
        #expect(ids.count > 990)
        #expect(ids.allSatisfy { (Int64($0) ?? 0) > 0 })
    }
}
