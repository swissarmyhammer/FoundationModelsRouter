// A 128-bit, lexicographically time-sortable identifier (ULID) in Crockford
// base32. Correctness — encoding, decoding, spec conformance, overflow — is
// owned by the yaslab/ULID.swift library; this file re-exports that `ULID`
// type and adds a thin compatibility shim so the router's call sites keep the
// API our design assumes.
//
// A ULID is a 48-bit millisecond timestamp followed by 80 bits of randomness.
// Because the timestamp occupies the most-significant bits, ULIDs created in
// time order also sort in time order — both as their 128-bit value and as their
// canonical 26-character text. The router uses ULIDs as the recording root id
// and as each session's span id (see the plan's "Transcripts & recording"
// section).
//
// The library `ULID` already conforms to `Sendable`, `Hashable`, `Equatable`,
// `Comparable` (timestamp-ordered), `Codable` (a 26-character Crockford base32
// string), and `CustomStringConvertible` (`description` is the 26-char string),
// so none of that is reimplemented here.
@_exported import ULID

extension ULID {
    /// Generates a new ULID for the current instant with random low bits.
    ///
    /// - Returns: A freshly generated ULID.
    public static func generate() -> ULID {
        ULID()
    }

    /// Parses a canonical 26-character Crockford base32 ULID string.
    ///
    /// - Parameter string: The text to decode.
    /// - Returns: The decoded ULID, or `nil` if `string` is not a valid ULID.
    public init?(_ string: String) {
        self.init(ulidString: string)
    }
}
