import CryptoKit
import Foundation

/// The lowercase hex text of the SHA-256 digest of a key: a file name that
/// any file system takes, whatever characters the key holds.
enum SHA256Hex {
    /// The format of one byte of the digest: two lowercase hex digits.
    private static let byteFormat = "%02x"

    /// The hex text of the digest of `key`.
    ///
    /// - Parameter key: The key, hashed as its UTF-8 bytes.
    /// - Returns: The 64 lowercase hex digits of the digest.
    static func text(of key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: byteFormat, $0) }.joined()
    }
}
