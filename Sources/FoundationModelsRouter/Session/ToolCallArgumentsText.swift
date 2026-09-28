import FoundationModels

/// The text of the arguments of a tool call, as the repetition watch reads it
/// (task ^dzw15st).
///
/// The arguments are a JSON object. A snippet of code in them is a JSON string,
/// so its line breaks are `\n` escapes, and the detector splits only on a real
/// line feed. So the watch reads the string values of the JSON, decoded: each
/// escape becomes its character. A key is not text, and a number, a Boolean
/// and `null` are not text. Each closed string value ends with a line feed,
/// so the last line of a value is a complete line, and two values never join
/// into one line. A string that the text does not close (a JSON text cut in
/// the middle) gives its text so far, with no line feed added.
enum ToolCallArgumentsText {
    /// The text of the arguments of each call of `calls`, in order.
    ///
    /// - Parameter calls: The calls of a `.toolCalls` entry.
    /// - Returns: The joined text of the string values of each call.
    static func text(of calls: Transcript.ToolCalls) -> String {
        calls.map { text(ofArgumentsJSON: $0.arguments.jsonString) }.joined()
    }

    /// The string values of `json`, decoded, each closed value on lines of
    /// its own.
    ///
    /// - Parameter json: The JSON text of the arguments, complete or cut.
    /// - Returns: The text of the string values, in the order of the text.
    static func text(ofArgumentsJSON json: String) -> String {
        var scanner = JSONStringValueScanner(json: json)
        return scanner.valuesText()
    }
}

/// Reads the string values of one JSON text, from start to end.
///
/// The scanner does not check the grammar of the JSON: it finds each string,
/// decodes it, and tells a key from a value by the colon that follows a key.
/// This is enough for the arguments that a model generates, which the SDK
/// already parsed, and it accepts a text cut in the middle.
private struct JSONStringValueScanner {
    /// The scalar that opens and closes a JSON string.
    private static let quote: Unicode.Scalar = "\""

    /// The scalar that starts an escape in a JSON string.
    private static let backslash: Unicode.Scalar = "\\"

    /// The scalar that follows a key.
    private static let colon: Unicode.Scalar = ":"

    /// The line feed that ends each closed value.
    private static let lineFeed = "\n"

    /// The count of scalars of the `\u` marker of an escape.
    private static let unicodeEscapeMarkerLength = 2

    /// The count of hex digits of a `\u` escape.
    private static let unicodeEscapeDigitCount = 4

    /// The radix of the digits of a `\u` escape.
    private static let hexRadix = 16

    /// The UTF-16 code units of a high surrogate.
    private static let highSurrogates: ClosedRange<UInt32> = 0xD800...0xDBFF

    /// The UTF-16 code units of a low surrogate.
    private static let lowSurrogates: ClosedRange<UInt32> = 0xDC00...0xDFFF

    /// The first scalar value that a surrogate pair encodes.
    private static let supplementaryPlaneBase: UInt32 = 0x10000

    /// The count of value bits that each surrogate of a pair carries.
    private static let surrogatePayloadBits: UInt32 = 10

    /// The decoded character of each single-character escape.
    private static let simpleEscapes: [Unicode.Scalar: String] = [
        "\"": "\"", "\\": "\\", "/": "/", "b": "\u{8}", "f": "\u{c}", "n": "\n", "r": "\r", "t": "\t",
    ]

    /// The scalars of the JSON text.
    private let scalars: [Unicode.Scalar]

    /// The position of the next scalar to read.
    private var position = 0

    /// Makes a scanner at the start of `json`.
    ///
    /// - Parameter json: The JSON text.
    init(json: String) {
        scalars = Array(json.unicodeScalars)
    }

    /// The text of every string value, from the position to the end.
    ///
    /// - Returns: The decoded values. Each closed value ends with a line feed.
    mutating func valuesText() -> String {
        var text = ""
        while let string = nextString() {
            guard string.isClosed else { return text + string.value }
            guard !nextNonSpaceIsColon() else { continue }
            text += string.value.hasSuffix(Self.lineFeed) ? string.value : string.value + Self.lineFeed
        }
        return text
    }

    /// Reads up to the next string and reads the string.
    ///
    /// - Returns: The decoded string and whether the text closed it, or `nil`
    ///   when no string is left.
    private mutating func nextString() -> (value: String, isClosed: Bool)? {
        while position < scalars.count, scalars[position] != Self.quote {
            position += 1
        }
        guard position < scalars.count else { return nil }
        position += 1
        return readString()
    }

    /// Reads one string from after its open quote.
    ///
    /// - Returns: The decoded string, and `false` when the text ends before
    ///   the close quote. An escape that the text cuts is left out.
    private mutating func readString() -> (value: String, isClosed: Bool) {
        var value = ""
        while position < scalars.count {
            let scalar = scalars[position]
            position += 1
            if scalar == Self.quote {
                return (value, true)
            }
            guard scalar == Self.backslash else {
                value.unicodeScalars.append(scalar)
                continue
            }
            guard let decoded = readEscape() else { return (value, false) }
            value += decoded
        }
        return (value, false)
    }

    /// Reads one escape from after its backslash.
    ///
    /// - Returns: The decoded text, or `nil` when the text ends inside the
    ///   escape. An escape that JSON does not name gives its own character.
    private mutating func readEscape() -> String? {
        guard position < scalars.count else { return nil }
        let marker = scalars[position]
        position += 1
        guard marker == "u" else {
            return Self.simpleEscapes[marker] ?? String(marker)
        }
        guard let unit = readHexUnit() else { return nil }
        return decodedScalar(startingWith: unit).map { String($0) } ?? ""
    }

    /// The scalar that `unit` starts: the unit itself, or the pair that it
    /// forms with a `\u` low surrogate that follows it.
    ///
    /// - Parameter unit: The UTF-16 code unit of a `\u` escape.
    /// - Returns: The scalar, or `nil` for a lone surrogate.
    private mutating func decodedScalar(startingWith unit: UInt32) -> Unicode.Scalar? {
        guard Self.highSurrogates.contains(unit) else { return Unicode.Scalar(unit) }
        let restart = position
        guard let low = readLowSurrogateEscape() else {
            position = restart
            return nil
        }
        let high = unit - Self.highSurrogates.lowerBound
        let lowPart = low - Self.lowSurrogates.lowerBound
        return Unicode.Scalar(Self.supplementaryPlaneBase + (high << Self.surrogatePayloadBits) + lowPart)
    }

    /// Reads a `\u` escape of a low surrogate at the position.
    ///
    /// - Returns: The code unit, or `nil` when the text holds no such escape.
    private mutating func readLowSurrogateEscape() -> UInt32? {
        guard position + 1 < scalars.count, scalars[position] == Self.backslash, scalars[position + 1] == "u"
        else { return nil }
        position += Self.unicodeEscapeMarkerLength
        guard let unit = readHexUnit(), Self.lowSurrogates.contains(unit) else { return nil }
        return unit
    }

    /// Reads the hex digits of a `\u` escape.
    ///
    /// - Returns: The code unit, or `nil` when the text ends first or a digit
    ///   is not hex.
    private mutating func readHexUnit() -> UInt32? {
        let end = position + Self.unicodeEscapeDigitCount
        guard end <= scalars.count else { return nil }
        var digits = String.UnicodeScalarView()
        digits.append(contentsOf: scalars[position..<end])
        guard let unit = UInt32(String(digits), radix: Self.hexRadix) else { return nil }
        position = end
        return unit
    }

    /// Whether the next scalar that is not white space is a colon: the
    /// string before it was a key.
    ///
    /// - Returns: `true` after a key.
    private func nextNonSpaceIsColon() -> Bool {
        let next = scalars[position...].first { !$0.properties.isWhitespace }
        return next == Self.colon
    }
}
