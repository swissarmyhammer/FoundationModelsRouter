import Testing
import Foundation

@testable import FoundationModelsRouter

/// Smoke tests for our `ULID` shim contract. Correctness of the encoding,
/// spec vectors, and overflow handling is owned by the yaslab/ULID.swift
/// library; these tests assert only the thin compatibility surface our design
/// relies on: `ULID.generate()`, string init `ULID(_:)`, the 26-char
/// `description`, timestamp-ordered `Comparable`, and `Codable`.
@Suite("ULID")
struct ULIDTests {
    /// The Crockford base32 alphabet a canonical ULID encodes to.
    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A deterministic generator so the random component of a ULID is fixed in
    /// tests; ordering must come from the timestamp prefix, not chance.
    private struct FixedGenerator: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    @Test("generate yields a 26-char string that round-trips through ULID(_:)")
    func roundTrip() {
        let ulid = ULID.generate()
        let text = ulid.description

        #expect(text.count == 26)
        #expect(text.allSatisfy { Self.crockford.contains($0) })

        let decoded = ULID(text)
        #expect(decoded == ulid)
        #expect(decoded?.description == text)
    }

    @Test("ids sort chronologically by timestamp")
    func ordersByTimestamp() {
        var generator = FixedGenerator()
        let earlier = ULID(timestamp: Date(timeIntervalSince1970: 1), generator: &generator)
        let later = ULID(timestamp: Date(timeIntervalSince1970: 2), generator: &generator)

        #expect(earlier < later)
        #expect(earlier.description < later.description)
    }

    @Test("Codable encodes to the 26-char string and decodes back equal")
    func codableRoundTrip() throws {
        let ulid = ULID.generate()

        let data = try JSONEncoder().encode(ulid)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == "\"\(ulid.description)\"")

        let decoded = try JSONDecoder().decode(ULID.self, from: data)
        #expect(decoded == ulid)
    }
}
