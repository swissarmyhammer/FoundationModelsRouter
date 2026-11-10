import Foundation

/// Walks the metadata section of a prefix of a GGUF file as far as the prefix
/// goes, and tells where the next read of the header should end.
///
/// `GGUFHeader.parse(prefix:)` stops at the end of a prefix with
/// `GGUFHeaderError.needsMoreBytes(atLeast:)`, whose byte count reaches only
/// the next value it reads: one string, or one array element. A read sized
/// from that count alone takes a round trip for each doubling of the prefix,
/// because the tokenizer arrays of a real model run to many megabytes. The
/// scan finds the array that runs past the prefix, which the parse does not
/// report, and predicts the end of the metadata from the count and the type
/// of its elements.
struct GGUFMetadataScan {
    /// The array whose elements run past the end of the prefix.
    let openArray: OpenArray

    /// An array value of the metadata whose elements run past the end of a
    /// prefix.
    struct OpenArray: Equatable {
        /// The metadata key of the array.
        let key: String

        /// The `gguf_type` of the elements.
        let elementType: UInt32

        /// The count of the elements.
        let count: Int

        /// The offset of the first element, from the start of the file.
        let elementsStart: Int

        /// The count of the elements that end inside the prefix.
        let readCount: Int

        /// The offset of the end of the last element that ends inside the
        /// prefix, from the start of the file.
        let readEnd: Int
    }

    /// The bytes of the magic, the version and the tensor count: the start of
    /// the file before the count of the metadata values.
    private static let leadByteCount = 16

    /// The type of a string value (`GGUF_TYPE_STRING`).
    private static let stringType: UInt32 = 8

    /// The type of an array value (`GGUF_TYPE_ARRAY`).
    private static let arrayType: UInt32 = 9

    /// The byte count of each value type that has a fixed size, by its type
    /// (`gguf_type`).
    private static let fixedByteCounts: [UInt32: Int] = [
        0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8,
    ]

    /// The largest count or length that the scan accepts: the bound that
    /// `GGUFHeader.parse(prefix:)` sets, a value more than any GGUF file
    /// holds.
    private static let largestCount = 1 << 40

    /// The metadata key of the tokens of the vocabulary.
    private static let vocabularyTokensKey = "tokenizer.ggml.tokens"

    /// The bytes of the metadata that each token of the vocabulary predicts,
    /// from the start of the token array.
    ///
    /// A GGUF tokenizer writes a value for each token after the tokens: the
    /// token types, and the scores or the BPE merges. The early tokens of a
    /// vocabulary are short, so the average of the tokens read so far
    /// predicts too few bytes. The budget covers the token, its type and a
    /// merge of about the same length, with a margin: Qwen3.5 (248,320
    /// tokens) needs 44 bytes for each token, and the Qwen3.5 and DeepSeek
    /// vocabularies of llama.cpp need 39.
    static let vocabularyEntryByteBudget = 48

    /// The divisor of the predicted bytes left in an array that gives the
    /// headroom the read adds to them: a quarter more.
    private static let headroomDivisor = 4

    /// Scans a prefix of a GGUF file.
    ///
    /// - Parameter prefix: The first bytes of a GGUF file.
    /// - Returns: The scan, or `nil` when the prefix ends outside an array,
    ///   when it holds the whole metadata section, or when its bytes are not
    ///   a GGUF metadata section that the scan reads.
    init?(prefix: Data) {
        var cursor = Cursor(data: prefix)
        do {
            try cursor.skip(Self.leadByteCount)
            let valueCount = try cursor.count()
            for _ in 0..<valueCount {
                let key = try cursor.string()
                let type = try cursor.integer(UInt32.self)
                if let open = try Self.skipValue(of: type, key: key, cursor: &cursor) {
                    openArray = open
                    return
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// The offset at which the next read of the header should end, from the
    /// start of the file.
    ///
    /// For the token array of the vocabulary, the offset is the start of the
    /// array plus ``vocabularyEntryByteBudget`` for each token, which covers
    /// the arrays that follow it. For another array, it is the end of the
    /// array, with a quarter more of the bytes left in it: the exact end for
    /// elements of a fixed size, and for strings the average of the strings
    /// read so far.
    ///
    /// - Returns: The offset, or `nil` for an array of strings whose first
    ///   string runs past the prefix: no average predicts its end.
    func predictedEnd() -> Int? {
        let open = openArray
        if open.key == Self.vocabularyTokensKey, open.elementType == Self.stringType {
            return open.elementsStart + open.count * Self.vocabularyEntryByteBudget
        }
        let remaining: Int
        if let elementBytes = Self.fixedByteCounts[open.elementType] {
            remaining = (open.count - open.readCount) * elementBytes
        } else {
            guard open.readCount > 0 else { return nil }
            let average = Double(open.readEnd - open.elementsStart) / Double(open.readCount)
            remaining = Int(min(average * Double(open.count - open.readCount), Double(Self.largestCount)))
        }
        return open.readEnd + remaining + remaining / Self.headroomDivisor
    }

    /// Skips one metadata value.
    ///
    /// - Parameters:
    ///   - type: The `gguf_type` of the value.
    ///   - key: The metadata key.
    ///   - cursor: The cursor at the value.
    /// - Returns: The array, when the value is an array whose elements run
    ///   past the prefix; `nil` when the value ends inside it.
    /// - Throws: ``Cursor/PrefixEnd`` when the prefix ends outside the
    ///   elements of an array, or ``Cursor/Unreadable`` for a type that GGUF
    ///   does not define.
    private static func skipValue(of type: UInt32, key: String, cursor: inout Cursor) throws -> OpenArray? {
        switch type {
        case stringType:
            try cursor.skipString()
            return nil
        case arrayType:
            return try skipArray(key: key, cursor: &cursor)
        default:
            try cursor.skip(fixedByteCount(of: type))
            return nil
        }
    }

    /// Skips the elements of an array value.
    ///
    /// - Parameters:
    ///   - key: The metadata key.
    ///   - cursor: The cursor at the element type of the array.
    /// - Returns: The array, when its elements run past the prefix; `nil`
    ///   when they end inside it.
    /// - Throws: ``Cursor/PrefixEnd`` when the prefix ends before the first
    ///   element, or ``Cursor/Unreadable`` for an element type that GGUF does
    ///   not define in an array.
    private static func skipArray(key: String, cursor: inout Cursor) throws -> OpenArray? {
        let elementType = try cursor.integer(UInt32.self)
        let count = try cursor.count()
        let elementsStart = cursor.offset
        let open = { (readCount: Int, readEnd: Int) in
            OpenArray(
                key: key, elementType: elementType, count: count, elementsStart: elementsStart,
                readCount: readCount, readEnd: readEnd)
        }
        guard elementType == stringType else {
            let elementBytes = try fixedByteCount(of: elementType)
            let readCount = min(cursor.remaining / elementBytes, count)
            guard readCount == count else { return open(readCount, elementsStart + readCount * elementBytes) }
            try cursor.skip(count * elementBytes)
            return nil
        }
        for index in 0..<count {
            let elementStart = cursor.offset
            do {
                try cursor.skipString()
            } catch is Cursor.PrefixEnd {
                return open(index, elementStart)
            }
        }
        return nil
    }

    /// Gives the byte count of a value type that has a fixed size.
    ///
    /// - Parameter type: The `gguf_type`.
    /// - Returns: The byte count.
    /// - Throws: ``Cursor/Unreadable`` for a type that has no fixed size.
    private static func fixedByteCount(of type: UInt32) throws -> Int {
        guard let count = fixedByteCounts[type] else { throw Cursor.Unreadable() }
        return count
    }
}

extension GGUFMetadataScan {
    /// Reads little-endian values from a prefix of a GGUF file.
    fileprivate struct Cursor {
        /// The prefix ends before the bytes that a read needs.
        struct PrefixEnd: Error {}

        /// The bytes are not a metadata section that the scan reads.
        struct Unreadable: Error {}

        /// The bytes of the prefix.
        let data: Data

        /// The offset of the next byte to read, from the start of the file.
        private(set) var offset = 0

        /// The count of the bytes of the prefix after ``offset``.
        var remaining: Int {
            data.count - offset
        }

        /// Skips bytes.
        ///
        /// - Parameter count: The count of the bytes.
        /// - Throws: ``PrefixEnd`` when the prefix ends before them.
        mutating func skip(_ count: Int) throws {
            guard count <= remaining else { throw PrefixEnd() }
            offset += count
        }

        /// Reads a little-endian integer.
        ///
        /// - Parameter type: The type of the integer.
        /// - Returns: The integer.
        /// - Throws: ``PrefixEnd`` when the prefix ends before it.
        mutating func integer<Value: FixedWidthInteger>(_ type: Value.Type) throws -> Value {
            let start = data.startIndex + offset
            try skip(MemoryLayout<Value>.size)
            return data[start..<(data.startIndex + offset)].reversed().reduce(Value.zero) { ($0 << 8) | Value($1) }
        }

        /// Reads a 64-bit count or length.
        ///
        /// - Returns: The count.
        /// - Throws: ``Unreadable`` for a count more than any GGUF file holds,
        ///   or ``PrefixEnd``.
        mutating func count() throws -> Int {
            let value = try integer(UInt64.self)
            guard value <= UInt64(GGUFMetadataScan.largestCount) else { throw Unreadable() }
            return Int(value)
        }

        /// Reads a string: a 64-bit length and the UTF-8 bytes.
        ///
        /// - Returns: The string.
        /// - Throws: The error of ``skipString()``.
        mutating func string() throws -> String {
            let start = data.startIndex + offset
            try skipString()
            let bytes = data[start..<(data.startIndex + offset)].dropFirst(MemoryLayout<UInt64>.size)
            return String(decoding: bytes, as: UTF8.self)
        }

        /// Skips a string: a 64-bit length and the UTF-8 bytes.
        ///
        /// - Throws: The error of ``count()``, or ``PrefixEnd``.
        mutating func skipString() throws {
            try skip(try count())
        }
    }
}
