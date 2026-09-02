/// A structured record a tool hands the Router about what its call did, for
/// example a file-change set.
///
/// The Router does not know the record's type. It carries `contentJSON` as an
/// opaque JSON document and `schemaName` as the name of that document's type,
/// the same shape `SegmentPayload.structure` uses. A host decodes the document
/// by its schema name. The Router never renders an attachment to the model.
///
/// A tool attaches a record through ``ToolContext/attach(_:)``.
public struct ToolCallAttachment: Sendable, Equatable, Codable {
    /// The name of the type `contentJSON` encodes, so a host can decode it.
    public let schemaName: String

    /// The JSON document the tool owns. The Router reads nothing in it.
    public let contentJSON: String

    /// Creates an attachment.
    ///
    /// - Parameters:
    ///   - schemaName: The name of the type `contentJSON` encodes.
    ///   - contentJSON: The JSON document the tool owns.
    public init(schemaName: String, contentJSON: String) {
        self.schemaName = schemaName
        self.contentJSON = contentJSON
    }
}
