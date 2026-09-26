import FoundationModels

/// The rule a host gives to keep a tool output through compaction.
///
/// The rule gets the call that made the output and the output itself, and
/// returns `true` to protect the output. A compaction keeps a protected
/// `.toolOutput` entry word for word in the new snapshot, next to the
/// summary. It also keeps the `.toolCalls` entry that holds its call, reduced
/// to the protected calls, in the original order. A kept output never stays
/// without its call. The protected entries count against the target: the
/// summary gets the room that the target leaves after them.
///
/// The rule sees the call, so a host can decide on the tool name and on the
/// arguments, for example a `skills` call whose `op` argument is `use skill`.
/// No tag, marker or wrapper in the output text is necessary.
///
/// A call and its output pair by id: the `.toolCalls` entry holds the call
/// whose id is the id of the `.toolOutput` entry. An output that pairs with no
/// call is never protected.
///
/// A host sets the rule on ``SessionConfiguration/toolOutputProtection``. The
/// rule is a closure, so the session does not record it: a host gives it again
/// when it restores a session, as it gives the tools. A fork inherits it.
///
/// - Parameters:
///   - call: The tool call that made `output`.
///   - output: The tool output to keep or to compact.
/// - Returns: `true` to keep `output` word for word through compaction.
public typealias ToolOutputProtection = @Sendable (_ call: Transcript.ToolCall, _ output: Transcript.ToolOutput) -> Bool

/// The protected tool outputs of one list of transcript entries, and the calls
/// that made them, found by a ``ToolOutputProtection`` rule.
///
/// The pairing scope starts again at each `.prompt` entry, the same scope a
/// submission diff uses (see ``ToolCallOutputPairing``). Thus one value can read
/// one submission, or a whole transcript whose header holds kept pairs.
struct ProtectedToolOutputs {
    /// The id suffix of a `.toolCalls` entry reduced to its protected calls.
    ///
    /// A reduced entry has content its original does not have, so it takes an
    /// id of its own. A compaction then records it as a new entry, and a restore
    /// rebuilds the reduced entry and not the original one.
    static let reducedToolCallsIdSuffix = "-protected"

    /// The entries this value reads, in original order.
    let entries: [Transcript.Entry]

    /// The positions in ``entries`` of the protected `.toolOutput` entries.
    private let outputPositions: Set<Int>

    /// For each position in ``entries`` of a `.toolCalls` entry that holds a
    /// protected call, the positions of its protected calls in that entry.
    private let callPositions: [Int: Set<Int>]

    /// Finds the protected tool outputs of `entries`.
    ///
    /// - Parameters:
    ///   - entries: The entries to read, in original order.
    ///   - rule: The host rule, or `nil` to protect nothing.
    init(entries: [Transcript.Entry], rule: ToolOutputProtection?) {
        self.entries = entries
        var outputPositions: Set<Int> = []
        var callPositions: [Int: Set<Int>] = [:]
        if let rule {
            var scope = PairingScope()
            for (position, entry) in entries.enumerated() {
                guard let answered = scope.read(entry, at: position), rule(answered.announced.call, answered.output)
                else { continue }
                outputPositions.insert(position)
                callPositions[answered.announced.entryPosition, default: []].insert(answered.announced.callPosition)
            }
        }
        self.outputPositions = outputPositions
        self.callPositions = callPositions
    }

    /// Whether the entry at `position` is a protected `.toolOutput` entry.
    ///
    /// - Parameter position: A position in ``entries``.
    /// - Returns: `true` when the rule protects that entry.
    func isProtectedOutput(at position: Int) -> Bool {
        outputPositions.contains(position)
    }

    /// The entries a compaction keeps when it replaces ``entries``: each `.toolCalls`
    /// entry that holds a protected call, reduced to its protected calls, and
    /// each protected `.toolOutput` entry, in original order.
    var keptEntries: [Transcript.Entry] {
        entries.indices.compactMap(keptEntry(at:))
    }

    /// The entry a compaction keeps in place of the entry at `position`, or
    /// `nil` when the compaction keeps nothing of it.
    ///
    /// - Parameter position: A position in ``entries``.
    /// - Returns: The protected output unchanged, the `.toolCalls` entry
    ///   unchanged when all its calls are protected, the `.toolCalls` entry
    ///   reduced to its protected calls under a new id, or `nil`.
    private func keptEntry(at position: Int) -> Transcript.Entry? {
        if isProtectedOutput(at: position) { return entries[position] }
        guard let protectedCalls = callPositions[position], case .toolCalls(let calls) = entries[position] else {
            return nil
        }
        guard protectedCalls.count < calls.count else { return entries[position] }
        let reduced = calls.enumerated().filter { protectedCalls.contains($0.offset) }.map(\.element)
        return .toolCalls(Transcript.ToolCalls(id: calls.id + Self.reducedToolCallsIdSuffix, reduced))
    }
}

/// The calls one pairing scope announced, and the outputs that answered them.
private struct PairingScope {
    /// One announced call, and where it stands.
    struct AnnouncedCall {
        /// The position of the `.toolCalls` entry that holds the call.
        let entryPosition: Int

        /// The position of the call in that entry.
        let callPosition: Int

        /// The call itself.
        let call: Transcript.ToolCall
    }

    /// One tool output, and the announced call it answers.
    struct AnsweredCall {
        /// The announced call the output answers.
        let announced: AnnouncedCall

        /// The output that answers the call.
        let output: Transcript.ToolOutput
    }

    /// Every call this scope announced, in request order.
    private var announced: [AnnouncedCall] = []

    /// The positions in ``announced`` of the calls an output already answered.
    private var answered: Set<Int> = []

    /// Reads one entry into this scope.
    ///
    /// A `.prompt` entry starts a new scope. A `.toolCalls` entry announces
    /// its calls. A `.toolOutput` entry answers one announced call, found with
    /// ``ToolCallOutputPairing/completedToolCallId(forOutputEntryId:dispatched:completed:)``.
    ///
    /// - Parameters:
    ///   - entry: The entry to read.
    ///   - position: The entry's position in its list.
    /// - Returns: The answered call when `entry` is a `.toolOutput` entry
    ///   that pairs with an announced call, otherwise `nil`.
    mutating func read(_ entry: Transcript.Entry, at position: Int) -> AnsweredCall? {
        switch entry {
        case .prompt:
            self = PairingScope()
            return nil
        case .toolCalls(let calls):
            announced += calls.enumerated().map {
                AnnouncedCall(entryPosition: position, callPosition: $0.offset, call: $0.element)
            }
            return nil
        case .toolOutput(let output):
            return answer(output)
        case .instructions, .response, .reasoning:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Pairs `output` with the announced call it answers, and marks that call
    /// as answered.
    ///
    /// - Parameter output: The tool output.
    /// - Returns: The answered call, or `nil` when no announced call pairs.
    private mutating func answer(_ output: Transcript.ToolOutput) -> AnsweredCall? {
        let callId = ToolCallOutputPairing.completedToolCallId(
            forOutputEntryId: output.id,
            dispatched: announced.map(\.call.id),
            completed: Set(answered.map { announced[$0].call.id }))
        guard
            let slot = announced.indices.first(where: {
                !answered.contains($0) && announced[$0].call.id == callId
            })
        else { return nil }
        answered.insert(slot)
        return AnsweredCall(announced: announced[slot], output: output)
    }
}
