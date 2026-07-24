import FoundationModels

/// # Test-only sample tools (task 4ce0a1k)
///
/// Two small, real `FoundationModels.Tool` conformances that give this demo
/// genuine tool-call/tool-output transcript traffic to fold, instead of only
/// the plain prompt/response turns the original fixture-reading loop
/// produced. Both are deliberately simple — they exist to demonstrate the
/// harness's tool-calling + compaction combination, not to be useful tools in
/// their own right.
///
/// - ``DocumentGeneratorTool`` manufactures configurably large filler text —
///   the context pressure that fills the session's small working context —
///   delivered as a `.toolOutput` entry so the auto-compaction fold below has
///   real ``Sources/FoundationModelsRouter/Compaction/ToolOutputElision.swift``-eligible
///   content to elide, not just plain response text.
/// - ``RecordFactTool``/``RecallFactTool`` are a matched pair backed by one
///   shared ``FactStore`` actor — the fact-store sample tool. The demo has
///   the model call ``RecordFactTool`` before the fold and ``RecallFactTool``
///   after it, proving continuity of a different kind than plain
///   conversational recall: the model must still remember *that* a fact was
///   stored under a given key, and remain able to actually call a tool to
///   retrieve it, after its transcript has been folded.

/// Generates configurably-sized filler text on demand — this demo's context
/// pressure, delivered through a real tool call instead of a plain user
/// turn, so it produces genuine `.toolCalls`/`.toolOutput` transcript entries
/// for the compaction pipeline's `ToolOutputElision` stage to fold.
struct DocumentGeneratorTool: Tool {
    let name = "generate_document"
    let description = """
        Generates a filler document about the given topic, roughly the requested \
        number of paragraphs long. Call this to fetch background material to summarize.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The topic the generated document should nominally be about.")
        let topic: String
        @Guide(description: "Roughly how many paragraphs of filler text to generate.")
        let paragraphs: Int
    }

    /// Synthesizes `arguments.paragraphs` paragraphs of repetitive filler
    /// text about `arguments.topic` — deterministic and cheap, since the
    /// point is consuming context budget, not saying anything interesting.
    ///
    /// - Parameter arguments: The topic and requested paragraph count.
    /// - Returns: The generated filler document.
    func call(arguments: Arguments) async throws -> String {
        let paragraphCount = max(1, arguments.paragraphs)
        let sentence =
            "This paragraph discusses \(arguments.topic) in exhaustive, repetitive detail so as to consume context budget."
        let paragraph = Array(repeating: sentence, count: 8).joined(separator: " ")
        return Array(repeating: paragraph, count: paragraphCount).joined(separator: "\n\n")
    }
}

/// The shared, in-process state behind ``RecordFactTool``/``RecallFactTool``
/// — an `actor` so concurrent tool calls (unlikely in this single-threaded
/// scripted demo, but a real possibility for a live model session) never
/// race on the underlying dictionary.
actor FactStore {
    private var facts: [String: String] = [:]

    /// Stores `value` under `key`, overwriting any previous value.
    func record(key: String, value: String) {
        facts[key] = value
    }

    /// Returns the value previously recorded under `key`, or `nil` if none
    /// was ever recorded.
    func recall(key: String) -> String? {
        facts[key]
    }
}

/// Records a named fact into a shared ``FactStore`` — half of the
/// fact-store sample tool pair; see this file's own doc comment.
struct RecordFactTool: Tool {
    let name = "record_fact"
    let description = "Records a named fact for later recall via the paired recall_fact tool."

    let store: FactStore

    @Generable
    struct Arguments {
        @Guide(description: "The fact's identifying key.")
        let key: String
        @Guide(description: "The value to remember for this key.")
        let value: String
    }

    func call(arguments: Arguments) async throws -> String {
        await store.record(key: arguments.key, value: arguments.value)
        return "recorded \(arguments.key)"
    }
}

/// Recalls a previously recorded fact from a shared ``FactStore`` — the
/// other half of the fact-store sample tool pair; see this file's own doc
/// comment.
struct RecallFactTool: Tool {
    let name = "recall_fact"
    let description = "Recalls a fact previously recorded via the paired record_fact tool."

    let store: FactStore

    @Generable
    struct Arguments {
        @Guide(description: "The key of a previously recorded fact to retrieve.")
        let key: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let value = await store.recall(key: arguments.key) else {
            return "no fact recorded for \(arguments.key)"
        }
        return value
    }
}
