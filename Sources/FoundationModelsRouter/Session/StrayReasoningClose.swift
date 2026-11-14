import FoundationModels

/// A stray `</think>`: a close tag in the response text of an attempt, after
/// the reasoning of its pass is already closed (task ^07vtf4a).
///
/// Recursive Flint (`mlx-community/flint-oQ8e`) always reasons, and its
/// `<think>` and `</think>` are plain text, not special tokens. On a status
/// turn it wrote its status line, then a literal `</think>`, then a
/// fabricated router message in the exact shape of the next feedback
/// (`[agents] agents (<id>) running: …`), an invented agent verdict, and a
/// loop, up to the 16,384-token ceiling (SWE-bench run of 2026-11-14 on
/// django-13447: two runaways of about 3 minutes each). Qwen3.8 never did
/// this on the same instance.
///
/// The reasoning parser of the engine takes the first `</think>` of a pass
/// as the close of the reasoning, and gives the text after it to the
/// `.response` entry. So the close of the reasoning never shows in a
/// response entry, and a `</think>` that does show there is stray: the model
/// pretends that a new turn began. Only a `.response` entry counts. The
/// reasoning and the arguments of a tool call are not the reply.
struct StrayReasoningClose: Sendable, Equatable {
    /// The close tag of the `<think>` protocol of the always-reasoning models
    /// that the router runs (Recursive Flint, DeepSeek-R1).
    static let tag = "</think>"

    /// The `Transcript.Entry.id` of the `.response` entry that holds the tag.
    let entryId: String

    /// The UTF-8 length of the text of the entry before the tag: the text
    /// that the reply keeps.
    let keptUTF8Length: Int

    /// The first stray close among `texts`: the first `.response` entry whose
    /// text holds ``tag``, at the first tag of that text.
    ///
    /// - Parameter texts: The watched texts of the attempt, in transcript
    ///   order (``WatchedText/attemptTexts(in:excluding:)``).
    /// - Returns: The stray close, or `nil` when no response text holds the
    ///   tag.
    static func first(in texts: [WatchedText]) -> StrayReasoningClose? {
        texts.lazy.filter { !$0.isReasoning && !$0.isToolCalls }.compactMap { watched in
            watched.text.range(of: tag).map { range in
                StrayReasoningClose(
                    entryId: watched.entryId, keptUTF8Length: watched.text.utf8.distance(
                        from: watched.text.startIndex, to: range.lowerBound))
            }
        }.first
    }

    /// `entries` with the text of the entry of this close cut before the
    /// tag. An entry with no text left leaves the transcript
    /// (``RepeatedPartRemoval/render(of:applying:)``).
    ///
    /// - Parameter entries: The rebuilt transcript of the stopped attempt.
    /// - Returns: The transcript that the turn ends with.
    func cutting(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        RepeatedPartRemoval.render(of: entries, applying: RenderCut(keptUTF8Lengths: [entryId: keptUTF8Length]))
    }

    /// The reply of the turn: the text of the entry of this close in `cut`,
    /// or an empty text when the tag was the first text of the entry.
    ///
    /// - Parameter cut: The transcript that ``cutting(_:)`` gave.
    /// - Returns: The reply text.
    func reply(in cut: [Transcript.Entry]) -> String {
        WatchedText.attemptTexts(in: cut, excluding: []).last { $0.entryId == entryId }?.text ?? ""
    }
}

/// The marker a session sets when its watch stops a model call at a stray
/// `</think>` (task ^07vtf4a), and the facts it needs to end the turn.
struct StrayReasoningCloseStop: Sendable {
    /// Where the stray close is.
    let close: StrayReasoningClose

    /// The live transcript that the watch read last, before the stop.
    let liveEntries: [Transcript.Entry]
}

/// ``RoutedSessionActor``'s stop at a stray `</think>` (task ^07vtf4a).
///
/// The repetition watch of a model that always reasons
/// (``ReasoningControl/alwaysOn``) reads the response text of each pass for
/// ``StrayReasoningClose/tag``. When it finds one, the session stops the
/// model call there, drops the tag and what follows it, and ends the turn as
/// if the model had ended it: the attempt closes with
/// ``FinishReason/completed``, the reply is the text before the tag, and no
/// recovery runs. A switchable model (Qwen3), or a model with no control of
/// its reasoning, keeps each `</think>` it writes: the evidence is of an
/// always-reasoning model only, and a tag in the response text of any other
/// model stays its own text.
///
/// The stop rides the repetition watch, so a detection that is not enabled
/// (``RepetitionDetection/isEnabled``) stops nothing. A call that ends by
/// itself before the stop lands keeps its text whole, as a late stop of the
/// watch does not count.
extension RoutedSessionActor {
    /// Stops the model call in flight at the stray close that the watch
    /// named by `watchId` found.
    ///
    /// Nothing happens when that watch is not the active one, or when
    /// another stop of the call is set (``noStopOutstanding``). Otherwise
    /// the session sets the marker, logs the stop, and cancels
    /// ``inFlightModelCall``.
    ///
    /// - Parameters:
    ///   - close: Where the stray close is.
    ///   - liveEntries: The live transcript the watch read last.
    ///   - watchId: The watch that found it.
    func noteStrayReasoningClose(_ close: StrayReasoningClose, liveEntries: [Transcript.Entry], watchId: UInt64) {
        guard repetitionWatch.activeWatchId == watchId, noStopOutstanding else { return }
        repetitionWatch.strayReasoningClose = StrayReasoningCloseStop(close: close, liveEntries: liveEntries)
        sessionLogger(.reasoningStop).notice(
            "a stray </think> in the response text ends the model call",
            metadata: [RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)"])
        inFlightModelCall?.cancel()
    }

    /// Takes the stray-close marker of the attempt that just failed.
    ///
    /// A stop outstanding against the answer wins: the failure is then a user
    /// stop, and the marker is dropped.
    ///
    /// - Returns: The marker, or `nil` when the watch did not stop the attempt
    ///   at a stray close.
    func takeStrayReasoningCloseStop() -> StrayReasoningCloseStop? {
        defer { repetitionWatch.strayReasoningClose = nil }
        guard !isWorkCancelled else { return nil }
        return repetitionWatch.strayReasoningClose
    }

    /// Ends the turn that the watch stopped at a stray close, as if the model
    /// had ended it.
    ///
    /// The rebuilt transcript of the attempt (``InFlightTranscript``) is cut
    /// before the tag (``StrayReasoningClose/cutting(_:)``), goes into
    /// ``backend``, and the ordinary diff records it with
    /// ``FinishReason/completed``. The record and the render are the same
    /// transcript, so a restored session gives the model the same render,
    /// and no event of a render change is needed. The usage of the stopped
    /// call is measured before the replace
    /// (``measureStoppedCall(liveEntries:finishReason:logCategory:rebuilt:render:)``):
    /// the model wrote the tag and the text after it, so its output counts.
    ///
    /// - Parameters:
    ///   - stop: The stray-close marker of the stopped attempt.
    ///   - attempt: The stopped attempt.
    /// - Returns: The reply of the turn: the response text before the tag.
    func endTurnAtStrayReasoningClose(_ stop: StrayReasoningCloseStop, attempt: StoppedAttempt) async -> String {
        let usageOfAttempt = Self.usageDelta(before: attempt.usageBefore, after: backend.usageTokenCounts())
        let rebuilt = InFlightTranscript.rebuilt(
            settledEntries: backend.transcriptEntries(), sources: [stop.liveEntries],
            entryIdsBeforeAttempt: attempt.entryIdsBeforeAttempt, composedPrompt: attempt.composedPrompt)
        let cut = stop.close.cutting(rebuilt)
        let measure = measureStoppedCall(
            liveEntries: stop.liveEntries, finishReason: .completed, logCategory: .reasoningStop, rebuilt: rebuilt,
            render: cut)
        await replaceBackendAndRecord(
            with: cut, attempt: attempt, usageOfAttempt: measure.addingStoppedCall(to: usageOfAttempt),
            stopReason: .completed, measure: measure)
        return stop.close.reply(in: cut)
    }
}
