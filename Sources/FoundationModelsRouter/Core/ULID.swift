import Foundation

/// A 128-bit, lexicographically time-sortable identifier (ULID) in Crockford
/// base32.
///
/// A ULID is a 48-bit millisecond timestamp followed by 80 bits of randomness.
/// Because the timestamp occupies the most-significant bits, ULIDs created in
/// time order also sort in time order — both as their 128-bit value and as
/// their canonical 26-character text. The router uses ULIDs as the recording
/// root id and as each session's span id (see the plan's "Transcripts &
/// recording" section).
///
/// The type is pure value semantics — no dependency on MLX — and is `Sendable`,
/// `Hashable`, `Comparable`, `Codable`, and `CustomStringConvertible`. It
/// encodes to and decodes from the 26-character Crockford base32 string.
public struct ULID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The full 128-bit identifier: a 48-bit timestamp in the high bits followed
    /// by 80 bits of randomness in the low bits.
    public let value: UInt128

    /// The Crockford base32 alphabet, excluding `I`, `L`, `O`, and `U` to avoid
    /// transcription ambiguity. Each character encodes five bits.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Reverse lookup from a character to its five-bit value. Lenient per
    /// Crockford: lowercase is accepted, `I`/`L` map to `1`, and `O` maps to
    /// `0`. Any other character is rejected by being absent.
    private static let decodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            let value = UInt8(index)
            table[character] = value
            table[Character(character.lowercased())] = value
        }
        // Crockford transcription aliases for ambiguous glyphs.
        for character in ["I", "i", "L", "l"] { table[Character(character)] = 1 }
        for character in ["O", "o"] { table[Character(character)] = 0 }
        return table
    }()

    /// The number of characters in a canonical ULID string.
    private static let length = 26

    /// Mask selecting the 48 timestamp bits.
    private static let timestampMask: UInt64 = (1 << 48) - 1

    /// Mask selecting the 80 randomness bits.
    private static let randomnessMask: UInt128 = (UInt128(1) << 80) - 1

    /// Creates a ULID from a millisecond timestamp and randomness.
    ///
    /// - Parameters:
    ///   - timestamp: Milliseconds since the Unix epoch. Only the low 48 bits
    ///     are used; higher bits are discarded.
    ///   - randomness: The random component. Only the low 80 bits are used;
    ///     higher bits are discarded.
    public init(timestamp: UInt64, randomness: UInt128) {
        let ts = UInt128(timestamp & Self.timestampMask)
        let rand = randomness & Self.randomnessMask
        self.value = (ts << 80) | rand
    }

    /// Creates a ULID from a raw 128-bit value.
    ///
    /// - Parameter value: The full identifier, timestamp in the high 48 bits and
    ///   randomness in the low 80 bits.
    public init(value: UInt128) {
        self.value = value
    }

    /// Parses a canonical 26-character Crockford base32 ULID string.
    ///
    /// - Parameter string: The text to decode.
    /// - Returns: The decoded ULID, or `nil` if `string` is not exactly 26
    ///   Crockford base32 characters, or if it would represent a value larger
    ///   than 128 bits.
    public init?(_ string: String) {
        guard string.count == Self.length else { return nil }
        var accumulator: UInt128 = 0
        for (index, character) in string.enumerated() {
            guard let digit = Self.decodeTable[character] else { return nil }
            // The first of 26 base32 characters carries the top three meaningful
            // bits; a value above 7 would overflow the 128-bit space.
            if index == 0 && digit > 7 { return nil }
            accumulator = (accumulator << 5) | UInt128(digit)
        }
        self.value = accumulator
    }

    /// The 48-bit millisecond timestamp embedded in the identifier.
    public var timestamp: UInt64 {
        UInt64(value >> 80)
    }

    /// The canonical 26-character Crockford base32 representation.
    public var description: String {
        var characters = [Character](repeating: "0", count: Self.length)
        var remaining = value
        for offset in stride(from: Self.length - 1, through: 0, by: -1) {
            characters[offset] = Self.alphabet[Int(remaining & 0x1F)]
            remaining >>= 5
        }
        return String(characters)
    }

    /// Generates a new ULID for the given instant with cryptographically random
    /// low bits.
    ///
    /// - Parameter timestamp: Milliseconds since the Unix epoch; defaults to the
    ///   current time. Inject a fixed value for deterministic ordering tests.
    /// - Returns: A freshly generated ULID.
    public static func generate(timestamp: UInt64 = currentMilliseconds()) -> ULID {
        let high = UInt128(UInt16.random(in: .min ... .max)) << 64
        let low = UInt128(UInt64.random(in: .min ... .max))
        return ULID(timestamp: timestamp, randomness: high | low)
    }

    /// The current time in milliseconds since the Unix epoch.
    public static func currentMilliseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    /// Orders ULIDs by their 128-bit value, which sorts by timestamp first and
    /// breaks ties on randomness.
    public static func < (lhs: ULID, rhs: ULID) -> Bool {
        lhs.value < rhs.value
    }

    /// Encodes the ULID as its canonical 26-character string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Decodes a ULID from its canonical 26-character string.
    ///
    /// - Throws: `DecodingError.dataCorrupted` if the string is not a valid ULID.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let ulid = ULID(string) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid ULID string: \(string)"
                )
            )
        }
        self = ulid
    }
}
