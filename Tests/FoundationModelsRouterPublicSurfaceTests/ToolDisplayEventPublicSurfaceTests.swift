import Testing

import FoundationModelsRouter

/// Holds ``SessionEvent/toolDisplay(_:)``, ``ToolDisplayEvent`` and
/// ``ToolDisplayContent`` to the public surface of the router (task ^twha0gz).
///
/// This target imports only the router module, with a plain import. The router
/// re-exports the Extras declarations of `ToolDisplayEvent` and
/// `ToolDisplayContent`, so a router user writes them and the nested
/// `ToolDisplayEvent.Kind` with no import of FoundationModelsExtras, also in a
/// public declaration. The compiler is the first assertion: when the
/// re-export goes, ``DisplayChunkReader`` does not compile.
@Suite("SessionEvent.toolDisplay over a plain router import")
struct ToolDisplayEventPublicSurfaceTests {
    /// The text of the probe chunk.
    private static let chunkText = "first output line"

    /// A display event that adds ``chunkText`` to the output of a call.
    private static let chunkEvent = ToolDisplayEvent(
        tool: "shell", op: "run command", correlationID: "run-1", kind: .contentChunk(.text(chunkText)))

    /// A host reads the text of a chunk from the session event.
    @Test("a host reads the chunk text of a toolDisplay session event through the router names")
    func aHostReadsTheChunkText() {
        let event = SessionEvent.toolDisplay(Self.chunkEvent)

        #expect(DisplayChunkReader.text(of: event) == Self.chunkText)
        #expect(DisplayChunkReader.text(of: .textReset) == nil)
    }
}

/// A public type that names `ToolDisplayEvent.Kind` and `ToolDisplayContent`
/// in its public members, as the host of a router user does. It is public,
/// and at the top level, only because a public declaration is what the suite
/// checks: with a plain typealias, the compiler rejects `ToolDisplayEvent.Kind`
/// in a public member, because the file does not import
/// FoundationModelsExtras.
public enum DisplayChunkReader {
    /// The text that `kind` adds to the output of a call.
    ///
    /// - Parameter kind: What a display event tells the client.
    /// - Returns: The text of a text chunk, or `nil` for each other kind.
    public static func text(of kind: ToolDisplayEvent.Kind) -> String? {
        guard case .contentChunk(let content) = kind else { return nil }
        return text(of: content)
    }

    /// The text of `content`.
    ///
    /// - Parameter content: One part of the display output of a tool.
    /// - Returns: The text of a text part, or `nil` for a diff or JSON.
    public static func text(of content: ToolDisplayContent) -> String? {
        guard case .text(let text) = content else { return nil }
        return text
    }

    /// The text that `event` adds to the output of a call.
    ///
    /// - Parameter event: A session event.
    /// - Returns: The text of a ``SessionEvent/toolDisplay(_:)`` text chunk,
    ///   or `nil` for each other event.
    public static func text(of event: SessionEvent) -> String? {
        guard case .toolDisplay(let display) = event else { return nil }
        return text(of: display.kind)
    }
}
