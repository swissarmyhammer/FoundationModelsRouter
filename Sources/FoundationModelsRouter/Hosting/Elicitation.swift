import Foundation

/// Which interaction an ``ElicitationRequest`` asks the host to run.
///
/// Wire values follow the MCP spec: `"form"` (2025-06-18) and `"url"`
/// (2025-11-25). A request whose JSON omits the `mode` key decodes as
/// ``form`` — the spec's original, implicit mode.
public enum ElicitationMode: String, Codable, Sendable, Equatable {
    /// The host presents a flat form described by
    /// ``ElicitationRequest/requestedSchema`` and returns the filled values
    /// on an accepting ``ElicitationResponse``.
    case form

    /// The host asks the user to open ``ElicitationRequest/url``; the
    /// accept means only that the user agreed to open it, and the flow's
    /// completion arrives separately, addressed by the request's
    /// ``ElicitationRequest/elicitationId``.
    case url
}

/// A typed, MCP-spec-shaped request for user input, posted by a running
/// operation and presented by a host.
///
/// Every field mirrors the MCP specification's elicitation shapes (form
/// mode: 2025-06-18; URL mode: 2025-11-25): ``mode`` (omitted on the wire
/// decodes as ``ElicitationMode/form``), ``message``, form mode's
/// ``requestedSchema`` (the restricted flat-object subset, see
/// ``ElicitationRequestedSchema``), and URL mode's ``url`` and
/// ``elicitationId``.
///
/// One deliberate deviation: this envelope requires ``elicitationId`` in
/// *both* modes, while MCP's form-mode `elicitation/create` carries none
/// (its form answer rides the JSON-RPC response instead). Here answers are
/// decoupled — they come down through `respond(elicitationId, response)` —
/// so form mode needs the address too; the router mints one at
/// construction, and an MCP passthrough adapting an inbound form-mode
/// request must mint one as well. Nothing the spec's shapes carry is
/// dropped, so passthrough loses nothing.
///
/// The ``elicitationId`` is a ULID, distinct from the run's own correlation:
/// one run can elicit more than once, and an answer addresses the
/// elicitation, not the run.
public struct ElicitationRequest: Codable, Sendable, Equatable {
    /// Which interaction this request asks the host to run.
    public let mode: ElicitationMode

    /// The human-readable question or instruction the host shows the user.
    public let message: String

    /// The identifier an answer addresses — distinct from the posting run's
    /// correlation, because one run can hold more than one pending
    /// elicitation at the same time.
    public let elicitationId: ULID

    /// The restricted flat-object schema describing the form to present.
    /// Non-nil exactly when ``mode`` is ``ElicitationMode/form``.
    public let requestedSchema: ElicitationRequestedSchema?

    /// The URL the user is asked to open. Non-nil exactly when ``mode`` is
    /// ``ElicitationMode/url``.
    public let url: URL?

    /// Creates a form-mode request.
    ///
    /// - Parameters:
    ///   - message: The question or instruction the host shows the user.
    ///   - elicitationId: The identifier an answer addresses.
    ///   - requestedSchema: The restricted flat-object schema describing the
    ///     form to present.
    public init(message: String, elicitationId: ULID, requestedSchema: ElicitationRequestedSchema) {
        self.mode = .form
        self.message = message
        self.elicitationId = elicitationId
        self.requestedSchema = requestedSchema
        self.url = nil
    }

    /// Creates a URL-mode request.
    ///
    /// - Parameters:
    ///   - message: The question or instruction the host shows the user.
    ///   - elicitationId: The identifier the flow's separate completion
    ///     addresses.
    ///   - url: The URL the user is asked to open.
    public init(message: String, elicitationId: ULID, url: URL) {
        self.mode = .url
        self.message = message
        self.elicitationId = elicitationId
        self.requestedSchema = nil
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case message
        case elicitationId
        case requestedSchema
        case url
    }

    /// Decodes a request, defaulting an omitted `mode` to
    /// ``ElicitationMode/form`` and requiring the decoded mode's payload:
    /// `requestedSchema` for form, `url` for URL.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decodeIfPresent(ElicitationMode.self, forKey: .mode) ?? .form
        self.mode = mode
        self.message = try container.decode(String.self, forKey: .message)
        self.elicitationId = try container.decode(ULID.self, forKey: .elicitationId)
        switch mode {
        case .form:
            self.requestedSchema = try container.decode(ElicitationRequestedSchema.self, forKey: .requestedSchema)
            self.url = nil
        case .url:
            self.requestedSchema = nil
            self.url = try container.decode(URL.self, forKey: .url)
        }
    }

    /// Encodes this request with its mode explicit — an explicit `"form"` is
    /// spec-valid, and never ambiguous the way relying on the omitted-key
    /// default would be.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(message, forKey: .message)
        try container.encode(elicitationId, forKey: .elicitationId)
        try container.encodeIfPresent(requestedSchema, forKey: .requestedSchema)
        try container.encodeIfPresent(url, forKey: .url)
    }
}

/// The restricted `requestedSchema` a form-mode ``ElicitationRequest``
/// carries: a flat object whose properties are all primitive
/// (``ElicitationPrimitiveSchema``), per the MCP spec's elicitation subset.
///
/// Flatness is enforced at construction: the Swift surface can only hold
/// primitive property schemas, and decoding a nested-object property throws
/// (see ``ElicitationPrimitiveSchema``), so a host form UI always stays a
/// flat form.
public struct ElicitationRequestedSchema: Codable, Sendable, Equatable {
    /// The form's fields, by property name — every one a primitive shape
    /// from the restricted subset.
    public let properties: [String: ElicitationPrimitiveSchema]

    /// The property names the user must fill, or `nil` when every field is
    /// optional.
    public let required: [String]?

    /// Creates a schema from its fields.
    ///
    /// - Parameters:
    ///   - properties: The form's fields, by property name.
    ///   - required: The property names the user must fill. Defaults to
    ///     `nil`.
    public init(properties: [String: ElicitationPrimitiveSchema], required: [String]? = nil) {
        self.properties = properties
        self.required = required
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
    }

    /// The one root `type` the subset allows.
    private static let objectTypeName = "object"

    /// Decodes a schema, rejecting any root whose `type` is not `"object"`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == Self.objectTypeName else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription:
                    "an elicitation requestedSchema root must be type \"object\", not \"\(type)\"")
        }
        self.properties = try container.decode([String: ElicitationPrimitiveSchema].self, forKey: .properties)
        self.required = try container.decodeIfPresent([String].self, forKey: .required)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.objectTypeName, forKey: .type)
        try container.encode(properties, forKey: .properties)
        try container.encodeIfPresent(required, forKey: .required)
    }
}

/// One property of an ``ElicitationRequestedSchema`` — restricted to the MCP
/// elicitation subset's primitive shapes: bounded/formatted strings,
/// numbers, booleans, and single/multi-select enums, each with an optional
/// default.
///
/// The subset's flatness lives in this type: there is no case that can hold
/// another object, so nesting is unrepresentable when building in Swift, and
/// decoding a property whose `type` is `"object"` (or anything else outside
/// the subset) throws.
public enum ElicitationPrimitiveSchema: Codable, Sendable, Equatable {
    /// A free-text string, optionally bounded and formatted
    /// (``ElicitationStringSchema``).
    case string(ElicitationStringSchema)

    /// A number or integer, optionally bounded
    /// (``ElicitationNumberSchema``).
    case number(ElicitationNumberSchema)

    /// A boolean (``ElicitationBooleanSchema``).
    case boolean(ElicitationBooleanSchema)

    /// A single-select enum — a string constrained to a fixed value list
    /// (``ElicitationSingleSelectSchema``).
    case singleSelect(ElicitationSingleSelectSchema)

    /// A multi-select enum — an array of strings constrained to a fixed
    /// value list (``ElicitationMultiSelectSchema``).
    case multiSelect(ElicitationMultiSelectSchema)

    /// The wire keys this dispatch inspects: the property's `type`, plus the
    /// `enum` key whose presence distinguishes a single-select from a
    /// free-text string.
    private enum DiscriminatorKeys: String, CodingKey {
        case type
        case enumValues = "enum"
    }

    /// Decodes one property by its `type`, throwing for `"object"` (the
    /// subset is flat) and for any type outside the subset.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "string":
            if container.contains(.enumValues) {
                self = .singleSelect(try ElicitationSingleSelectSchema(from: decoder))
            } else {
                self = .string(try ElicitationStringSchema(from: decoder))
            }
        case "number", "integer":
            self = .number(try ElicitationNumberSchema(from: decoder))
        case "boolean":
            self = .boolean(try ElicitationBooleanSchema(from: decoder))
        case "array":
            self = .multiSelect(try ElicitationMultiSelectSchema(from: decoder))
        case "object":
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription:
                    "nested object schemas are outside the MCP elicitation subset — every property must be primitive")
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription:
                    "property type \"\(type)\" is outside the MCP elicitation subset")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let schema): try schema.encode(to: encoder)
        case .number(let schema): try schema.encode(to: encoder)
        case .boolean(let schema): try schema.encode(to: encoder)
        case .singleSelect(let schema): try schema.encode(to: encoder)
        case .multiSelect(let schema): try schema.encode(to: encoder)
        }
    }
}

/// The string formats the MCP elicitation subset allows on a
/// ``ElicitationStringSchema``.
public enum ElicitationStringFormat: String, Codable, Sendable, Equatable {
    /// An email address.
    case email

    /// A URI.
    case uri

    /// A calendar date.
    case date

    /// A date with time.
    case dateTime = "date-time"
}

/// A free-text string property: optionally bounded (`minLength`/`maxLength`),
/// optionally formatted (``ElicitationStringFormat``), with an optional
/// default.
public struct ElicitationStringSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The minimum accepted length.
    public let minLength: Int?

    /// The maximum accepted length.
    public let maxLength: Int?

    /// The expected format, when the field is more specific than free text.
    public let format: ElicitationStringFormat?

    /// The pre-filled default, carried on the wire as `default`.
    public let defaultValue: String?

    /// Creates a string schema from its fields; every parameter defaults to
    /// `nil`.
    public init(
        title: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        format: ElicitationStringFormat? = nil,
        defaultValue: String? = nil
    ) {
        self.title = title
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.format = format
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case minLength
        case maxLength
        case format
        case defaultValue = "default"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.minLength = try container.decodeIfPresent(Int.self, forKey: .minLength)
        self.maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
        self.format = try container.decodeIfPresent(ElicitationStringFormat.self, forKey: .format)
        self.defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("string", forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(minLength, forKey: .minLength)
        try container.encodeIfPresent(maxLength, forKey: .maxLength)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

/// A numeric property — `"number"` or `"integer"` — optionally bounded
/// (`minimum`/`maximum`), with an optional default.
public struct ElicitationNumberSchema: Codable, Sendable, Equatable {
    /// Whether the field accepts any number or only integers — the wire
    /// `type` values `"number"` and `"integer"`.
    public enum NumberType: String, Codable, Sendable, Equatable {
        /// Any number.
        case number

        /// Integers only.
        case integer
    }

    /// Whether the field accepts any number or only integers.
    public let type: NumberType

    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The minimum accepted value.
    public let minimum: Double?

    /// The maximum accepted value.
    public let maximum: Double?

    /// The pre-filled default, carried on the wire as `default`.
    public let defaultValue: Double?

    /// Creates a number schema from its fields; every parameter but `type`
    /// defaults to `nil`.
    public init(
        type: NumberType,
        title: String? = nil,
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        defaultValue: Double? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case minimum
        case maximum
        case defaultValue = "default"
    }
}

/// A boolean property, with an optional default.
public struct ElicitationBooleanSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The pre-filled default, carried on the wire as `default`.
    public let defaultValue: Bool?

    /// Creates a boolean schema from its fields; every parameter defaults to
    /// `nil`.
    public init(title: String? = nil, description: String? = nil, defaultValue: Bool? = nil) {
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case defaultValue = "default"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.defaultValue = try container.decodeIfPresent(Bool.self, forKey: .defaultValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("boolean", forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

/// A single-select enum property: a string constrained to ``values``, with
/// optional display names and an optional default.
public struct ElicitationSingleSelectSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The accepted values, carried on the wire as `enum`.
    public let values: [String]

    /// Optional display names for ``values``, in the same order — the wire
    /// `enumNames`.
    public let enumNames: [String]?

    /// The pre-selected default, carried on the wire as `default`.
    public let defaultValue: String?

    /// Creates a single-select schema from its fields; every parameter but
    /// `values` defaults to `nil`.
    public init(
        title: String? = nil,
        description: String? = nil,
        values: [String],
        enumNames: [String]? = nil,
        defaultValue: String? = nil
    ) {
        self.title = title
        self.description = description
        self.values = values
        self.enumNames = enumNames
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case values = "enum"
        case enumNames
        case defaultValue = "default"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.values = try container.decode([String].self, forKey: .values)
        self.enumNames = try container.decodeIfPresent([String].self, forKey: .enumNames)
        self.defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("string", forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(values, forKey: .values)
        try container.encodeIfPresent(enumNames, forKey: .enumNames)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

/// A multi-select enum property: an array of strings constrained to
/// ``values`` (the wire shape `{"type": "array", "items": {"type": "string",
/// "enum": [...]}}`), optionally bounded (`minItems`/`maxItems`), with an
/// optional default selection.
public struct ElicitationMultiSelectSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The accepted values, carried on the wire as `items.enum`.
    public let values: [String]

    /// Optional display names for ``values``, in the same order — the wire
    /// `items.enumNames`, mirroring the single-select's.
    public let enumNames: [String]?

    /// The minimum number of selections.
    public let minItems: Int?

    /// The maximum number of selections.
    public let maxItems: Int?

    /// The pre-selected defaults, carried on the wire as `default`.
    public let defaultValue: [String]?

    /// Creates a multi-select schema from its fields; every parameter but
    /// `values` defaults to `nil`.
    public init(
        title: String? = nil,
        description: String? = nil,
        values: [String],
        enumNames: [String]? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        defaultValue: [String]? = nil
    ) {
        self.title = title
        self.description = description
        self.values = values
        self.enumNames = enumNames
        self.minItems = minItems
        self.maxItems = maxItems
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case items
        case minItems
        case maxItems
        case defaultValue = "default"
    }

    private enum ItemsKeys: String, CodingKey {
        case type
        case values = "enum"
        case enumNames
    }

    /// The one `items.type` the subset allows.
    private static let itemTypeName = "string"

    /// Decodes a multi-select, rejecting `items` that are not a string enum
    /// — an array of objects, or a free-form (enum-less) array, is outside
    /// the subset.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.nestedContainer(keyedBy: ItemsKeys.self, forKey: .items)
        let itemType = try items.decode(String.self, forKey: .type)
        guard itemType == Self.itemTypeName else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: items,
                debugDescription:
                    "multi-select items must be type \"string\", not \"\(itemType)\" — the MCP elicitation subset has no nested shapes")
        }
        self.values = try items.decode([String].self, forKey: .values)
        self.enumNames = try items.decodeIfPresent([String].self, forKey: .enumNames)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.minItems = try container.decodeIfPresent(Int.self, forKey: .minItems)
        self.maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems)
        self.defaultValue = try container.decodeIfPresent([String].self, forKey: .defaultValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("array", forKey: .type)
        var items = container.nestedContainer(keyedBy: ItemsKeys.self, forKey: .items)
        try items.encode(Self.itemTypeName, forKey: .type)
        try items.encode(values, forKey: .values)
        try items.encodeIfPresent(enumNames, forKey: .enumNames)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(minItems, forKey: .minItems)
        try container.encodeIfPresent(maxItems, forKey: .maxItems)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

/// One filled form value in an accepting ``ElicitationResponse`` — the value
/// shapes the restricted schema subset can produce: a string, a number, a
/// boolean, or a multi-select's array of strings.
public enum ElicitationValue: Codable, Sendable, Equatable {
    /// A string field's value (free text, formatted string, or
    /// single-select choice).
    case string(String)

    /// A number or integer field's value.
    case number(Double)

    /// A boolean field's value.
    case boolean(Bool)

    /// A multi-select field's chosen values.
    case stringArray([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolean = try? container.decode(Bool.self) {
            self = .boolean(boolean)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let strings = try? container.decode([String].self) {
            self = .stringArray(strings)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "an elicitation content value must be a string, number, boolean, or array of strings")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .boolean(let boolean): try container.encode(boolean)
        case .stringArray(let strings): try container.encode(strings)
        }
    }
}

/// The user's answer to an ``ElicitationRequest`` — the MCP three-action
/// model: `accept` | `decline` | `cancel`, with ``content`` present only on
/// a form-mode accept.
///
/// A URL-mode accept carries no content (the accept means only that the user
/// agreed to open the URL), and neither do decline and cancel — a declined
/// elicitation is not a cancelled run. Decoding enforces the invariant:
/// content alongside a decline or cancel throws.
public struct ElicitationResponse: Codable, Sendable, Equatable {
    /// The three actions the MCP spec defines for an elicitation answer.
    public enum Action: String, Codable, Sendable, Equatable {
        /// The user submitted the form (form mode) or agreed to open the URL
        /// (URL mode).
        case accept

        /// The user explicitly declined to answer.
        case decline

        /// The user dismissed the elicitation without answering.
        case cancel
    }

    /// How the user answered.
    public let action: Action

    /// The filled form values, by property name. Non-nil only when
    /// ``action`` is ``Action/accept`` on a form-mode request.
    public let content: [String: ElicitationValue]?

    /// The one memberwise entry point — private so the public
    /// ``accept(content:)``/``decline``/``cancel`` constructors are the only
    /// way to build a response, keeping content-on-decline unrepresentable.
    private init(action: Action, content: [String: ElicitationValue]?) {
        self.action = action
        self.content = content
    }

    /// An accepting response — with the filled form values for a form-mode
    /// request, or `nil` content for a URL-mode one.
    ///
    /// - Parameter content: The filled form values, or `nil`.
    /// - Returns: The accepting response.
    public static func accept(content: [String: ElicitationValue]?) -> ElicitationResponse {
        ElicitationResponse(action: .accept, content: content)
    }

    /// A declining response. Never carries content.
    public static let decline = ElicitationResponse(action: .decline, content: nil)

    /// A cancelling response. Never carries content.
    public static let cancel = ElicitationResponse(action: .cancel, content: nil)

    private enum CodingKeys: String, CodingKey {
        case action
        case content
    }

    /// Decodes a response, enforcing the content-only-on-accept invariant:
    /// content alongside a decline or cancel throws.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(Action.self, forKey: .action)
        self.content = try container.decodeIfPresent([String: ElicitationValue].self, forKey: .content)
        guard content == nil || action == .accept else {
            throw DecodingError.dataCorruptedError(
                forKey: .content, in: container,
                debugDescription: "elicitation content is only valid on an accept, not \(action.rawValue)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(content, forKey: .content)
    }
}
