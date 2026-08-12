import Foundation
import FoundationModels

/// Rebuilds a `GeneratedContent` from persisted JSON with the document's
/// object key order intact.
///
/// `GeneratedContent(json:)` parses values faithfully but reports a
/// structure's `orderedKeys` in dictionary order — an arbitrary order that
/// changes across processes — while a live structure's `GeneratedContent`
/// carries its true property order, and `GeneratedContent`'s equality
/// compares that order. The JSON text ``TranscriptEntryMapper`` persists (a
/// live content's own `jsonString`) is the one carrier of the true order, so
/// this decoder scans the document for the key order at every depth and
/// rebuilds each structure node through `GeneratedContent(kind:)` with that
/// order. Rebuilding through `GeneratedContent(kind:)` also restores
/// equality with a live structure: a json-parsed structure never compares
/// equal to a live one, even with identical ordered keys, and the kind-built
/// form does.
enum OrderPreservingGeneratedContentDecoder {
    /// Decodes `json` into a `GeneratedContent` whose structure nodes carry
    /// the document's own key order.
    ///
    /// The SDK parse (`GeneratedContent(json:)`) stays the value authority:
    /// scalars and arrays with no structure beneath them are returned
    /// exactly as it parsed them, and only structure nodes — wherever they
    /// sit — are rebuilt with the scanned document order. When the scan
    /// cannot pair a document node with the parsed one (a shape the SDK's
    /// own `jsonString` never produces), the parsed node is kept as is, so
    /// the result is never worse than the plain parse.
    ///
    /// - Parameter json: The JSON document to decode.
    /// - Returns: The decoded content, ordered like the document.
    /// - Throws: Whatever `GeneratedContent(json:)` throws for `json`.
    static func decode(json: String) throws -> GeneratedContent {
        let parsed = try GeneratedContent(json: json)
        var scanner = JSONDocumentOrderScanner(json: json)
        guard let order = scanner.scanDocument() else { return parsed }
        return ordered(parsed, by: order)
    }

    /// Returns `content` with every structure node rebuilt to carry the
    /// document key order `order` scanned for it.
    ///
    /// Structure nodes are always rebuilt through `GeneratedContent(kind:)`
    /// — the rebuild is what restores equality with a live structure, even
    /// when the parsed order already matches the document. An array node is
    /// rebuilt only when a structure sits beneath it; every other node is
    /// returned as parsed.
    ///
    /// - Parameters:
    ///   - content: The parsed node to reorder.
    ///   - order: The document order node scanned for `content`.
    private static func ordered(
        _ content: GeneratedContent, by order: JSONDocumentOrder
    ) -> GeneratedContent {
        switch (content.kind, order) {
        case (.structure(let properties, let parsedKeys), .object(let documentKeys, let members)):
            var orderedProperties: [String: GeneratedContent] = [:]
            for (key, value) in properties {
                orderedProperties[key] = ordered(value, by: members[key] ?? .scalar)
            }
            // The parsed key set stays authoritative: the scanned keys win
            // only when they name exactly the parsed properties (a document
            // with a repeated key, for example, scans more keys than the
            // parse keeps).
            let orderedKeys =
                documentKeys.count == properties.count && Set(documentKeys) == Set(properties.keys)
                ? documentKeys : parsedKeys
            return GeneratedContent(
                kind: .structure(properties: orderedProperties, orderedKeys: orderedKeys))
        case (.array(let elements), .array(let elementOrders))
        where elements.count == elementOrders.count:
            guard elementOrders.contains(where: \.containsObject) else { return content }
            let orderedElements = zip(elements, elementOrders).map { ordered($0, by: $1) }
            return GeneratedContent(kind: .array(orderedElements))
        default:
            return content
        }
    }
}

/// The object key order one JSON node carries — the single fact
/// `GeneratedContent(json:)` loses.
private indirect enum JSONDocumentOrder {
    /// An object node: its keys in document order, and each member's own
    /// order node.
    case object(orderedKeys: [String], members: [String: JSONDocumentOrder])

    /// An array node: one order node per element, in document order.
    case array([JSONDocumentOrder])

    /// A scalar node — a string, number, boolean, or null — which carries no
    /// key order.
    case scalar

    /// Whether an object node sits at or beneath this node — the only nodes
    /// a rebuild must reorder.
    var containsObject: Bool {
        switch self {
        case .object:
            return true
        case .array(let elements):
            return elements.contains(where: \.containsObject)
        case .scalar:
            return false
        }
    }
}

/// A minimal JSON scanner that extracts the object key order at every depth
/// of a document and skips everything else.
///
/// It scans documents `GeneratedContent(json:)` has already parsed, so it
/// never validates: any structural surprise makes the whole scan return
/// `nil`, and the caller keeps the parsed content unordered instead of
/// failing the decode.
private struct JSONDocumentOrderScanner {
    /// The characters JSON structural tokens and whitespace are matched
    /// against; a `Character` comparison is exact for all of them because
    /// none combines with a following scalar.
    private let characters: [Character]

    /// The scan position in ``characters``.
    private var index = 0

    /// The characters that end a scalar token: a separator, a closing
    /// bracket, or whitespace.
    private static let scalarTerminators: Set<Character> = [",", "}", "]", " ", "\t", "\n", "\r"]

    /// The JSON whitespace characters.
    private static let whitespace: Set<Character> = [" ", "\t", "\n", "\r"]

    /// How many characters a backslash escape occupies at minimum — the
    /// backslash and the character after it. Skipping both is enough to
    /// never mistake an escaped quote for the closing quote, because the
    /// longer `\u` escapes contain no quote in their remaining hex digits.
    private static let escapeSkipWidth = 2

    /// Creates a scanner over `json`.
    ///
    /// - Parameter json: The JSON document to scan.
    init(json: String) {
        characters = Array(json)
    }

    /// Scans the whole document and returns its order tree, or `nil` when
    /// the document does not scan as a single JSON value.
    mutating func scanDocument() -> JSONDocumentOrder? {
        scanValue()
    }

    /// Scans one JSON value of any kind.
    private mutating func scanValue() -> JSONDocumentOrder? {
        skipWhitespace()
        guard index < characters.count else { return nil }
        switch characters[index] {
        case "{":
            return scanObject()
        case "[":
            return scanArray()
        case "\"":
            return scanString() == nil ? nil : .scalar
        default:
            return scanScalarLiteral()
        }
    }

    /// Scans an object, collecting its keys in document order.
    private mutating func scanObject() -> JSONDocumentOrder? {
        index += 1
        var orderedKeys: [String] = []
        var members: [String: JSONDocumentOrder] = [:]
        skipWhitespace()
        if consume("}") { return .object(orderedKeys: orderedKeys, members: members) }
        while true {
            skipWhitespace()
            guard let key = scanString() else { return nil }
            skipWhitespace()
            guard consume(":"), let value = scanValue() else { return nil }
            orderedKeys.append(key)
            members[key] = value
            skipWhitespace()
            if consume(",") { continue }
            return consume("}") ? .object(orderedKeys: orderedKeys, members: members) : nil
        }
    }

    /// Scans an array, collecting one order node per element.
    private mutating func scanArray() -> JSONDocumentOrder? {
        index += 1
        var elements: [JSONDocumentOrder] = []
        skipWhitespace()
        if consume("]") { return .array(elements) }
        while true {
            guard let element = scanValue() else { return nil }
            elements.append(element)
            skipWhitespace()
            if consume(",") { continue }
            return consume("]") ? .array(elements) : nil
        }
    }

    /// Scans a string token and returns its decoded value — object keys must
    /// match the parsed properties exactly, so escapes are decoded by a real
    /// JSON decoder rather than by hand.
    private mutating func scanString() -> String? {
        guard index < characters.count, characters[index] == "\"" else { return nil }
        let start = index
        index += 1
        while index < characters.count {
            if characters[index] == "\\" {
                index += Self.escapeSkipWidth
                continue
            }
            if characters[index] == "\"" {
                index += 1
                let token = String(characters[start..<index])
                // Wrapped in an array so the decode never depends on
                // top-level-fragment support.
                return try? JSONDecoder().decode([String].self, from: Data("[\(token)]".utf8)).first
            }
            index += 1
        }
        return nil
    }

    /// Skips a number, `true`, `false`, or `null` token.
    private mutating func scanScalarLiteral() -> JSONDocumentOrder? {
        let start = index
        while index < characters.count, !Self.scalarTerminators.contains(characters[index]) {
            index += 1
        }
        return index > start ? .scalar : nil
    }

    /// Skips any run of JSON whitespace.
    private mutating func skipWhitespace() {
        while index < characters.count, Self.whitespace.contains(characters[index]) {
            index += 1
        }
    }

    /// Consumes `character` when it is next, reporting whether it was.
    ///
    /// - Parameter character: The structural character to consume.
    private mutating func consume(_ character: Character) -> Bool {
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }
}
