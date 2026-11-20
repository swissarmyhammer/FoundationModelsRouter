import Foundation
import FoundationModelsExtras

/// The provenance of an imported session (D209 (h)) as the frontmatter of
/// its `index.md` holds it, under the flat key `importedFrom` of the facts
/// (``SessionRecord``).
///
/// The value is a map with the keys of `SessionImportProvenance`. Each date
/// is ISO 8601 text in UTC with milliseconds, as every other date of the
/// record (``MillisecondDate``), so a provenance with whole milliseconds
/// reads back equal to the one that was saved. The map has no key for an
/// absent `sourceTitle` or an absent `sourceLastDate`.
struct RecordedImportProvenance: Codable {
    /// The provenance.
    let provenance: SessionImportProvenance

    /// The keys of the map.
    private enum CodingKeys: String, CodingKey {
        case agent, sourceID, sourcePath, sourceTitle, sourceLastDate, importedAt, skippedRecordCount
    }

    /// Wraps a provenance for the frontmatter.
    ///
    /// - Parameter provenance: The provenance of the facts.
    init(_ provenance: SessionImportProvenance) {
        self.provenance = provenance
    }

    /// A provenance with each date rounded to the nearest millisecond
    /// (``MillisecondDate/rounded(_:)``), the precision of the record. The
    /// facts hold a provenance in this form (``SessionFacts/importedFrom``).
    ///
    /// - Parameter provenance: A provenance.
    /// - Returns: `provenance` with its dates rounded.
    static func rounded(_ provenance: SessionImportProvenance) -> SessionImportProvenance {
        SessionImportProvenance(
            agent: provenance.agent, sourceID: provenance.sourceID, sourcePath: provenance.sourcePath,
            sourceTitle: provenance.sourceTitle,
            sourceLastDate: provenance.sourceLastDate.map(MillisecondDate.rounded),
            importedAt: MillisecondDate.rounded(provenance.importedAt),
            skippedRecordCount: provenance.skippedRecordCount)
    }

    /// Decodes the provenance from its map. An absent `sourceTitle` or an
    /// absent `sourceLastDate` is `nil`.
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
            sourceTitle: try container.decodeIfPresent(String.self, forKey: .sourceTitle),
            sourceLastDate: try container.decodeMillisecondDateIfPresent(forKey: .sourceLastDate),
            importedAt: try container.decodeMillisecondDate(forKey: .importedAt),
            skippedRecordCount: try container.decode(Int.self, forKey: .skippedRecordCount))
    }

    /// Encodes the provenance as its map, each date as text with
    /// milliseconds, and no key for an absent `sourceTitle` or an absent
    /// `sourceLastDate`.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: What the encoder throws.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provenance.agent, forKey: .agent)
        try container.encode(provenance.sourceID, forKey: .sourceID)
        try container.encode(provenance.sourcePath, forKey: .sourcePath)
        try container.encodeIfPresent(provenance.sourceTitle, forKey: .sourceTitle)
        try container.encodeIfPresent(
            provenance.sourceLastDate.map(MillisecondDate.text(of:)), forKey: .sourceLastDate)
        try container.encode(MillisecondDate.text(of: provenance.importedAt), forKey: .importedAt)
        try container.encode(provenance.skippedRecordCount, forKey: .skippedRecordCount)
    }
}
