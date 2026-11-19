import Foundation
import FoundationModelsExtras

/// The provenance of an imported session (D209 (h)) as the frontmatter of
/// its `index.md` holds it, under the flat key `importedFrom` of the facts
/// (``SessionRecord``).
///
/// The value is a map with the keys of `SessionImportProvenance`. Each date
/// is ISO 8601 text in UTC with milliseconds, as every other date of the
/// record (``MillisecondDate``), so a provenance with whole milliseconds
/// reads back equal to the one that was saved.
struct RecordedImportProvenance: Codable {
    /// The provenance.
    let provenance: SessionImportProvenance

    /// The keys of the map.
    private enum CodingKeys: String, CodingKey {
        case agent, sourceID, sourcePath, sourceLastDate, importedAt, skippedRecordCount
    }

    /// Wraps a provenance for the frontmatter.
    ///
    /// - Parameter provenance: The provenance of the facts.
    init(_ provenance: SessionImportProvenance) {
        self.provenance = provenance
    }

    /// Decodes the provenance from its map. An absent `sourceLastDate` is
    /// `nil`.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: A decoding error when a required key is absent, a key holds
    ///   the wrong type, or a date is not ISO 8601 text in UTC with
    ///   milliseconds.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provenance = SessionImportProvenance(
            agent: try container.decode(String.self, forKey: .agent),
            sourceID: try container.decode(String.self, forKey: .sourceID),
            sourcePath: try container.decode(String.self, forKey: .sourcePath),
            sourceLastDate: try container.decodeMillisecondDateIfPresent(forKey: .sourceLastDate),
            importedAt: try container.decodeMillisecondDate(forKey: .importedAt),
            skippedRecordCount: try container.decode(Int.self, forKey: .skippedRecordCount))
    }

    /// Encodes the provenance as its map, each date as text with
    /// milliseconds, and no key for an absent `sourceLastDate`.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: What the encoder throws.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provenance.agent, forKey: .agent)
        try container.encode(provenance.sourceID, forKey: .sourceID)
        try container.encode(provenance.sourcePath, forKey: .sourcePath)
        try container.encodeIfPresent(
            provenance.sourceLastDate.map(MillisecondDate.text(of:)), forKey: .sourceLastDate)
        try container.encode(MillisecondDate.text(of: provenance.importedAt), forKey: .importedAt)
        try container.encode(provenance.skippedRecordCount, forKey: .skippedRecordCount)
    }
}
