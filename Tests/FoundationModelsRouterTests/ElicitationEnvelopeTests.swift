import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the elicitation envelope (task ^xyksgns): the MCP-spec-shaped
/// ``ElicitationRequest``/``ElicitationResponse`` pair, the restricted
/// form-schema subset (flat objects with primitive properties only), the
/// third ``OperationEventKind`` case riding the event chain, and the
/// preamble-line rendering for that kind.
@Suite("Elicitation envelope: MCP-shaped request/response, third event kind")
struct ElicitationEnvelopeTests {
    private static func decodeRequest(_ json: String) throws -> ElicitationRequest {
        try JSONDecoder().decode(ElicitationRequest.self, from: Data(json.utf8))
    }

    private static func decodeResponse(_ json: String) throws -> ElicitationResponse {
        try JSONDecoder().decode(ElicitationResponse.self, from: Data(json.utf8))
    }

    // MARK: - Schema subset: every primitive shape is accepted

    @Test("the full restricted subset decodes: bounded/formatted strings, numbers, booleans, selects, defaults")
    func restrictedSubsetDecodes() throws {
        let json = """
            {
              "message": "Fill in the form",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "requestedSchema": {
                "type": "object",
                "properties": {
                  "name": {"type": "string", "title": "Name", "minLength": 1, "maxLength": 80},
                  "email": {"type": "string", "format": "email"},
                  "homepage": {"type": "string", "format": "uri"},
                  "birthday": {"type": "string", "format": "date"},
                  "meeting": {"type": "string", "format": "date-time"},
                  "age": {"type": "integer", "minimum": 0, "maximum": 150},
                  "score": {"type": "number", "default": 0.5},
                  "subscribed": {"type": "boolean", "default": true},
                  "color": {"type": "string", "enum": ["red", "green", "blue"], "default": "red"},
                  "toppings": {
                    "type": "array",
                    "items": {"type": "string", "enum": ["cheese", "olives"], "enumNames": ["Cheese", "Olives"]},
                    "minItems": 1,
                    "maxItems": 2,
                    "default": ["cheese"]
                  }
                },
                "required": ["name", "email"]
              }
            }
            """
        let request = try Self.decodeRequest(json)

        #expect(request.mode == .form)
        #expect(request.message == "Fill in the form")
        #expect(request.elicitationId.ulidString == "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        #expect(request.url == nil)
        let schema = try #require(request.requestedSchema)
        #expect(schema.required == ["name", "email"])
        #expect(schema.properties.count == 10)

        guard case .string(let name) = try #require(schema.properties["name"]) else {
            Issue.record("name should decode as a string schema")
            return
        }
        #expect(name.title == "Name")
        #expect(name.minLength == 1)
        #expect(name.maxLength == 80)

        guard case .string(let email) = try #require(schema.properties["email"]) else {
            Issue.record("email should decode as a string schema")
            return
        }
        #expect(email.format == .email)

        guard case .number(let age) = try #require(schema.properties["age"]) else {
            Issue.record("age should decode as a number schema")
            return
        }
        #expect(age.type == .integer)
        #expect(age.minimum == 0)
        #expect(age.maximum == 150)

        guard case .number(let score) = try #require(schema.properties["score"]) else {
            Issue.record("score should decode as a number schema")
            return
        }
        #expect(score.type == .number)
        #expect(score.defaultValue == 0.5)

        guard case .boolean(let subscribed) = try #require(schema.properties["subscribed"]) else {
            Issue.record("subscribed should decode as a boolean schema")
            return
        }
        #expect(subscribed.defaultValue == true)

        guard case .singleSelect(let color) = try #require(schema.properties["color"]) else {
            Issue.record("color should decode as a single-select schema")
            return
        }
        #expect(color.values == ["red", "green", "blue"])
        #expect(color.defaultValue == "red")

        guard case .multiSelect(let toppings) = try #require(schema.properties["toppings"]) else {
            Issue.record("toppings should decode as a multi-select schema")
            return
        }
        #expect(toppings.values == ["cheese", "olives"])
        #expect(toppings.enumNames == ["Cheese", "Olives"])
        #expect(toppings.minItems == 1)
        #expect(toppings.maxItems == 2)
        #expect(toppings.defaultValue == ["cheese"])
    }

    @Test("string format wire values decode into every format case")
    func stringFormatsDecode() throws {
        for (wire, format) in [
            ("email", ElicitationStringFormat.email),
            ("uri", ElicitationStringFormat.uri),
            ("date", ElicitationStringFormat.date),
            ("date-time", ElicitationStringFormat.dateTime),
        ] {
            let json = """
                {
                  "message": "m",
                  "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                  "requestedSchema": {
                    "type": "object",
                    "properties": {"field": {"type": "string", "format": "\(wire)"}}
                  }
                }
                """
            let request = try Self.decodeRequest(json)
            guard case .string(let schema) = try #require(request.requestedSchema?.properties["field"]) else {
                Issue.record("field should decode as a string schema for format \(wire)")
                return
            }
            #expect(schema.format == format)
        }
    }

    // MARK: - Schema subset: nested objects are rejected

    @Test("a nested-object property is rejected at construction (decode throws)")
    func nestedObjectPropertyRejected() {
        let json = """
            {
              "message": "m",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "requestedSchema": {
                "type": "object",
                "properties": {
                  "address": {"type": "object", "properties": {"street": {"type": "string"}}}
                }
              }
            }
            """
        #expect(throws: DecodingError.self) {
            try Self.decodeRequest(json)
        }
    }

    @Test("an array of objects is rejected — multi-select items must be a string enum")
    func arrayOfObjectsRejected() {
        let json = """
            {
              "message": "m",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "requestedSchema": {
                "type": "object",
                "properties": {
                  "people": {"type": "array", "items": {"type": "object", "properties": {}}}
                }
              }
            }
            """
        #expect(throws: DecodingError.self) {
            try Self.decodeRequest(json)
        }
    }

    @Test("an array whose items carry no enum is rejected — free-form arrays are outside the subset")
    func arrayWithoutEnumRejected() {
        let json = """
            {
              "message": "m",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "requestedSchema": {
                "type": "object",
                "properties": {
                  "tags": {"type": "array", "items": {"type": "string"}}
                }
              }
            }
            """
        #expect(throws: DecodingError.self) {
            try Self.decodeRequest(json)
        }
    }

    @Test("an unknown property type is rejected")
    func unknownPropertyTypeRejected() {
        let json = """
            {
              "message": "m",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "requestedSchema": {
                "type": "object",
                "properties": {"blob": {"type": "null"}}
              }
            }
            """
        #expect(throws: DecodingError.self) {
            try Self.decodeRequest(json)
        }
    }

    @Test("a requestedSchema whose root is not type object is rejected")
    func nonObjectRootRejected() {
        let json = """
            {
              "message": "m",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "requestedSchema": {"type": "string"}
            }
            """
        #expect(throws: DecodingError.self) {
            try Self.decodeRequest(json)
        }
    }

    // MARK: - Mode: omitted decodes as form; each mode carries its payload

    @Test("omitted mode decodes as form")
    func omittedModeDecodesAsForm() throws {
        let json = """
            {
              "message": "m",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "requestedSchema": {"type": "object", "properties": {}}
            }
            """
        let request = try Self.decodeRequest(json)
        #expect(request.mode == .form)
    }

    @Test("form mode without a requestedSchema is rejected")
    func formModeRequiresSchema() {
        let json = """
            {"message": "m", "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV"}
            """
        #expect(throws: DecodingError.self) {
            try Self.decodeRequest(json)
        }
    }

    @Test("url mode decodes with its url; url mode without a url is rejected")
    func urlModeCarriesURL() throws {
        let json = """
            {
              "mode": "url",
              "message": "Sign in to continue",
              "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
              "url": "https://example.com/auth"
            }
            """
        let request = try Self.decodeRequest(json)
        #expect(request.mode == .url)
        #expect(request.url == URL(string: "https://example.com/auth"))
        #expect(request.requestedSchema == nil)

        let missingURL = """
            {"mode": "url", "message": "m", "elicitationId": "01ARZ3NDEKTSV4RRFFQ69G5FAV"}
            """
        #expect(throws: DecodingError.self) {
            try Self.decodeRequest(missingURL)
        }
    }

    // MARK: - Request round trips

    @Test("a form request built through the typed API round-trips through Codable")
    func formRequestRoundTrips() throws {
        let request = ElicitationRequest(
            message: "Pick options",
            elicitationId: ULID.generate(),
            requestedSchema: ElicitationRequestedSchema(
                properties: [
                    "name": .string(ElicitationStringSchema(title: "Name", minLength: 1, maxLength: 10)),
                    "count": .number(ElicitationNumberSchema(type: .integer, minimum: 0, maximum: 5)),
                    "agree": .boolean(ElicitationBooleanSchema(defaultValue: false)),
                    "pick": .singleSelect(ElicitationSingleSelectSchema(values: ["a", "b"])),
                    "picks": .multiSelect(ElicitationMultiSelectSchema(values: ["x", "y"], maxItems: 2)),
                ],
                required: ["name"]
            )
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ElicitationRequest.self, from: data)
        #expect(decoded == request)
    }

    @Test("a url request built through the typed API round-trips through Codable")
    func urlRequestRoundTrips() throws {
        let request = ElicitationRequest(
            message: "Open this",
            elicitationId: ULID.generate(),
            url: URL(string: "https://example.com/flow")!
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ElicitationRequest.self, from: data)
        #expect(decoded == request)
        #expect(decoded.mode == .url)
    }

    // MARK: - Response: three actions, content only on accept

    @Test("each of the three actions round-trips through Codable")
    func responseActionsRoundTrip() throws {
        let responses: [ElicitationResponse] = [
            .accept(content: ["name": .string("Ada"), "count": .number(3), "agree": .boolean(true), "picks": .stringArray(["x"])]),
            .accept(content: nil),
            .decline,
            .cancel,
        ]
        for response in responses {
            let data = try JSONEncoder().encode(response)
            let decoded = try JSONDecoder().decode(ElicitationResponse.self, from: data)
            #expect(decoded == response)
        }
    }

    @Test("action wire values are accept, decline, cancel")
    func responseActionWireValues() throws {
        for (response, wire) in [
            (ElicitationResponse.accept(content: nil), "accept"),
            (ElicitationResponse.decline, "decline"),
            (ElicitationResponse.cancel, "cancel"),
        ] {
            let data = try JSONEncoder().encode(response)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["action"] as? String == wire)
        }
    }

    @Test("content on a decline or cancel is rejected at decode")
    func contentOnlyOnAccept() throws {
        let accepted = try Self.decodeResponse(
            """
            {"action": "accept", "content": {"name": "Ada"}}
            """)
        #expect(accepted.action == .accept)
        #expect(accepted.content == ["name": .string("Ada")])

        for action in ["decline", "cancel"] {
            #expect(throws: DecodingError.self) {
                try Self.decodeResponse(
                    """
                    {"action": "\(action)", "content": {"name": "Ada"}}
                    """)
            }
        }
    }

    @Test("a bare decline and a bare cancel decode with nil content")
    func declineAndCancelDecodeWithoutContent() throws {
        for (json, action) in [
            ("{\"action\": \"decline\"}", ElicitationResponse.Action.decline),
            ("{\"action\": \"cancel\"}", ElicitationResponse.Action.cancel),
        ] {
            let response = try Self.decodeResponse(json)
            #expect(response.action == action)
            #expect(response.content == nil)
        }
    }

    // MARK: - OperationEvent: third kind, optional typed request, back-compat

    private static func elicitationRequest(message: String = "Which one?") -> ElicitationRequest {
        ElicitationRequest(
            message: message,
            elicitationId: ULID.generate(),
            requestedSchema: ElicitationRequestedSchema(
                properties: ["pick": .singleSelect(ElicitationSingleSelectSchema(values: ["a", "b"]))]
            )
        )
    }

    @Test("a recorded OperationEvent JSON with no elicitation key still decodes (back-compat)")
    func recordedEventWithoutElicitationKeyDecodes() throws {
        let recorded = """
            {"tool": "shell", "op": "run command", "correlationID": "7", "kind": "completed", "detail": "exit 0"}
            """
        let event = try JSONDecoder().decode(OperationEvent.self, from: Data(recorded.utf8))
        #expect(event.kind == .completed)
        #expect(event.elicitation == nil)
    }

    @Test("an elicitation OperationEvent round-trips with its typed request intact")
    func elicitationEventRoundTripsTypedRequest() throws {
        let request = Self.elicitationRequest()
        let event = OperationEvent(
            tool: "snippet",
            op: "elicit form",
            correlationID: "3",
            kind: .elicitation,
            detail: "{}",
            elicitation: request
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)
        #expect(decoded == event)
        #expect(decoded.elicitation == request)
        #expect(decoded.kind == .elicitation)
    }

    // MARK: - renderedLine: the elicitation kind in the turn preamble

    @Test("renderedLine renders an elicitation event with its request message")
    func renderedLineRendersElicitation() {
        let event = OperationEvent(
            tool: "snippet",
            op: "elicit form",
            correlationID: "3",
            kind: .elicitation,
            detail: "{}",
            elicitation: Self.elicitationRequest(message: "Which account?")
        )

        #expect(OperationEventSegment.renderedLine(for: event) == "[snippet] elicit form (3) eliciting: Which account?")
    }

    @Test("renderedLine falls back to detail for an elicitation event missing its typed request")
    func renderedLineFallsBackToDetail() {
        let event = OperationEvent(
            tool: "snippet",
            op: "elicit form",
            correlationID: "3",
            kind: .elicitation,
            detail: "raw detail"
        )

        #expect(OperationEventSegment.renderedLine(for: event) == "[snippet] elicit form (3) eliciting: raw detail")
    }
}
