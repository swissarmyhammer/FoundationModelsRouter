import Foundation
import Testing

@testable import FoundationModelsRouter

/// Proves the KV cache setting of a profile (task ^vp19r4r): the key
/// `kvBits` of a profile file holds 8 or 4, or is absent for fp16, and no
/// other value decodes.
@Suite("A profile names the KV cache bits of its generation models")
struct ProfileKVBitsTests {
    /// A profile in JSON, with `kvBits` set to `value`, or without the key.
    ///
    /// - Parameter value: The text of the `kvBits` value, or `nil` for no key.
    /// - Returns: The JSON.
    private static func json(kvBits value: String?) -> Data {
        let kvBits = value.map { #", "kvBits": \#($0)"# } ?? ""
        return Data(
            """
            {"name": "p", "description": "d", "standard": ["org/s"], "flash": ["org/f"],
             "embedding": ["org/e"]\(kvBits)}
            """.utf8)
    }

    @Test("a profile with no kvBits stores an fp16 cache")
    func absentIsFloat16() throws {
        let profile = try JSONDecoder().decode(ProfileDefinition.self, from: Self.json(kvBits: nil))

        #expect(profile.kvCacheQuantization == nil)
        #expect(
            ProfileDefinition(name: "p", description: "d", standard: [], flash: [], embedding: [])
                .kvCacheQuantization == nil)
    }

    @Test(
        "kvBits 8 and 4 decode to the quantization of that width",
        arguments: [("8", KVCacheQuantization.bits8), ("4", .bits4)])
    func decodesWidth(text: String, quantization: KVCacheQuantization) throws {
        let profile = try JSONDecoder().decode(ProfileDefinition.self, from: Self.json(kvBits: text))

        #expect(profile.kvCacheQuantization == quantization)
    }

    @Test("kvBits of another width does not decode", arguments: ["6", "16", "0", "\"8\""])
    func rejectsOtherWidths(text: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProfileDefinition.self, from: Self.json(kvBits: text))
        }
    }

    @Test("a profile encodes kvBits as its width, and omits it for fp16")
    func encodesWidth() throws {
        var profile = ProfileDefinition(name: "p", description: "d", standard: [], flash: [], embedding: [])
        let float16 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        profile.kvCacheQuantization = .bits8
        let bits8 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]

        #expect(float16?["kvBits"] == nil)
        #expect(bits8?["kvBits"] as? Int == 8)
        #expect(
            try JSONDecoder().decode(ProfileDefinition.self, from: JSONEncoder().encode(profile))
                .kvCacheQuantization == .bits8)
    }
}
