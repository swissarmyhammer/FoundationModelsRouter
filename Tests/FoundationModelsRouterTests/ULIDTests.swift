import Testing
import Foundation

@testable import FoundationModelsRouter

@Suite("ULID")
struct ULIDTests {
    /// The Crockford base32 alphabet a canonical ULID encodes to.
    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    @Test("generate yields a 26-char Crockford string that round-trips")
    func roundTrip() {
        let ulid = ULID.generate()
        let text = ulid.description

        #expect(text.count == 26)
        #expect(text.allSatisfy { Self.crockford.contains($0) })

        let decoded = ULID(text)
        #expect(decoded == ulid)
        #expect(decoded?.description == text)

        // Crockford base32 decoding is case-insensitive: a lowercased canonical
        // string must decode to the same ULID as its uppercase form.
        let lowercase = text.lowercased()
        #expect(ULID(lowercase) == ulid)
        #expect(ULID(lowercase)?.description == text)
    }

    @Test("ids sort chronologically by timestamp prefix")
    func ordersByTimestamp() {
        // Earlier timestamp with maximal randomness must still sort before a
        // later timestamp with zero randomness: the timestamp prefix dominates.
        let earlier = ULID(timestamp: 1, randomness: .max)
        let later = ULID(timestamp: 2, randomness: 0)

        #expect(earlier < later)
        #expect(earlier.description < later.description)
    }

    @Test("encodes the canonical ULID spec timestamp vector")
    func encodesCanonicalSpecVector() {
        // The ULID spec's worked example: 1469918176385 ms encodes to these
        // first 10 characters. Pins canonical (interoperable) encoding so a
        // self-consistent-but-non-standard scheme would be caught.
        let ulid = ULID(timestamp: 1469918176385, randomness: 0)

        #expect(ulid.description.hasPrefix("01ARYZ6S41"))
        #expect(ulid.timestamp == 1469918176385)
    }

    @Test("equal timestamps break ties on randomness")
    func breaksTiesOnRandomness() {
        let low = ULID(timestamp: 7, randomness: 1)
        let high = ULID(timestamp: 7, randomness: 2)

        #expect(low < high)
    }

    @Test("invalid strings fail init returning nil")
    func rejectsInvalidStrings() {
        // Wrong length.
        #expect(ULID("") == nil)
        #expect(ULID("TOOSHORT") == nil)
        #expect(ULID(String(repeating: "0", count: 27)) == nil)

        // Non-base32 characters (U is excluded from Crockford base32).
        #expect(ULID(String(repeating: "U", count: 26)) == nil)
        #expect(ULID("01ARZ3NDEKTSV4RRFFQ69G5FA!") == nil)

        // First character beyond '7' overflows the 128-bit space.
        #expect(ULID(String(repeating: "Z", count: 26)) == nil)
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

    @Test("Codable rejects an invalid encoded string")
    func codableRejectsInvalid() {
        let badJSON = Data("\"not-a-ulid\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ULID.self, from: badJSON)
        }
    }
}
