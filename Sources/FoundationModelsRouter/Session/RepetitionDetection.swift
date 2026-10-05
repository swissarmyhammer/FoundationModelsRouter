import Foundation

/// The settings of the detector that stops a generate call that repeats
/// itself (task ^1hcwaqy).
///
/// A reasoning model can write the lines that it already wrote again, in a
/// different sequence, until the call reaches its ceiling. The share of new
/// lines then goes to zero and stays there. The session reads the reasoning,
/// the text and the tool-call arguments of the call in flight, line by line.
/// When one window of generated tokens holds no new line, the session stops
/// the call, keeps the repeated part out of the render that the model
/// receives next, and runs one more submission of the same answer with a
/// short prompt that tells the model to act. A tool call whose arguments fill
/// the window stops before the tool runs (task ^dzw15st).
///
/// The session sees a tool call only after the model ended it, so
/// ``passTokenLimit`` bounds a generation that the session cannot read.
///
/// A host passes this value through ``SessionConfiguration/repetitionDetection``.
/// A value that the host does not pass keeps its default. Each default is a
/// named constant, and the log line of a stop names each value in force.
/// The user confirmed the defaults on 2026-09-24.
public struct RepetitionDetection: Sendable, Equatable, Codable {
    /// The default of ``isEnabled``: the detector is on.
    public static let defaultIsEnabled = true

    /// The default of ``windowTokens``: 2,048 generated tokens.
    public static let defaultWindowTokens = 2_048

    /// The default of ``minimumLineLength``: 20 characters.
    public static let defaultMinimumLineLength = 20

    /// The default of ``recoveriesPerAnswer``: 2 recoveries.
    public static let defaultRecoveriesPerAnswer = 2

    /// The default of ``passTokenLimit``: 16,384 tokens (task ^dzw15st).
    public static let defaultPassTokenLimit = 16_384

    /// The default of ``comparesLineShapes``: the detector compares the
    /// shapes of lines (task ^ez2g5gw).
    public static let defaultComparesLineShapes = true

    /// The default of ``shortLineRepeatThreshold``: 8 occurrences
    /// (task ^ez2g5gw).
    public static let defaultShortLineRepeatThreshold = 8

    /// The default of ``reasoningTokenLimit``: 8,192 tokens (task ^hm9trt5).
    ///
    /// The value is a proposal from one SWE-bench run of 12 instances with
    /// `mlx-community/Qwen3.8-27B-mxfp4`: in the 10 instances that made a
    /// patch, the longest call made 9,584 tokens, and two instances that
    /// reasoned with no end made no patch. The owner must confirm it.
    public static let defaultReasoningTokenLimit = 8_192

    /// Whether the session watches the calls of its submissions. When `false`, no
    /// call stops for repetition.
    public var isEnabled: Bool

    /// The window, in generated tokens, that must hold at least one new
    /// line. Only the tokens of the lines that count and that repeat fill
    /// the window. A new line empties it. When it is full, the call stops.
    public var windowTokens: Int

    /// The minimum length, in characters, of a line that always counts. The
    /// length is that of the shape of the line (``comparesLineShapes``). A
    /// shorter line is short: it counts only after its shape occurs more
    /// than ``shortLineRepeatThreshold`` times in the call, so some lines
    /// that repeat by nature (```, `"""`, `)`, `...`) do not stop a call.
    public var minimumLineLength: Int

    /// How many times one answer goes on after a repetition stop. An answer
    /// is the chain of submissions from the first delivery to the final
    /// answer, so a continuation submission does not reset the count. After
    /// the last recovery, a stop leads to one final pass with the reasoning of
    /// the model off, and then the answer ends (task ^0dcsd3t).
    ///
    /// The key of this value in a stored `session.json` is
    /// `recoveriesPerTurn`, the name of the property before the rename, so
    /// an old recording loads (``CodingKeys``).
    public var recoveriesPerAnswer: Int

    /// The most output tokens that one generation pass of a submission may
    /// make, when the caller of the message names no ceiling (task ^dzw15st).
    ///
    /// The watch reads the transcript of the call in flight. The backend
    /// shows a tool call there only after the model ended it, and the MLX
    /// executor sends the arguments of a tool call only after the whole
    /// generation. So the watch cannot stop a model that writes the same line
    /// into a tool call again and again. This limit ends such a generation:
    /// each pass gets the smaller of the resolved context and this limit as
    /// its ceiling, and a pass that reaches it ends with
    /// ``FinishReason/maxTokens``. A ceiling that the caller names wins, and
    /// a detection that is not enabled sets no limit.
    public var passTokenLimit: Int

    /// Whether the detector compares the shape of each line, and not its
    /// exact text (task ^ez2g5gw). The shape of a line is its text without
    /// the white space at its two ends, with each run of decimal digits
    /// replaced by one `#`. Thus `- "Fixed #38692"` and `- "Fixed #38700"`
    /// have the same shape, and the second line is a repeat. When `false`,
    /// the shape is the text without the white space at its two ends.
    public var comparesLineShapes: Bool

    /// How many times one short shape can occur in a call before it counts
    /// (task ^ez2g5gw). A shape is short when it is shorter than
    /// ``minimumLineLength``. The first occurrences of a short shape, up to
    /// this number, are neither new nor repeated. Each occurrence after them
    /// is a repeat and fills the window. Thus some lines such as ``` or `)`
    /// do not stop a call, and a loop of many lines of one short shape does.
    public var shortLineRepeatThreshold: Int

    /// The most reasoning tokens of one generation pass (task ^hm9trt5), or
    /// `nil` or `0` for no limit.
    ///
    /// A reasoning model can think for a long time in one pass, write no
    /// tool call, and never act. The watch counts the tokens of the complete
    /// lines of each reasoning entry of the call in flight. When the
    /// reasoning entry that the call writes now reaches this limit, the
    /// session stops the call, keeps the reasoning so far, and runs a
    /// recovery with ``RoutedSessionActor/reasoningStopContinuationPrompt``
    /// and the reasoning of the model off, which tells the model to act. The
    /// recovery counts against ``recoveriesPerAnswer``. A detection that is
    /// not enabled sets no limit.
    public var reasoningTokenLimit: Int?

    /// The keys of the stored form. Each key is the name of its property,
    /// except ``recoveriesPerAnswer``: its key stays `recoveriesPerTurn`, and
    /// the schema version does not change (`generation-queue.md`, section 5.6).
    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case windowTokens
        case minimumLineLength
        case recoveriesPerAnswer = "recoveriesPerTurn"
        case passTokenLimit
        case comparesLineShapes
        case shortLineRepeatThreshold
        case reasoningTokenLimit
    }

    /// The text that replaces each run of decimal digits in the shape of a
    /// line (``comparesLineShapes``).
    static let digitRunPlaceholder = "#"

    /// Creates the settings. Each parameter defaults to its named default.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the session watches the calls of its submissions.
    ///   - windowTokens: The window, in generated tokens, that must hold at
    ///     least one new line.
    ///   - minimumLineLength: The minimum length of a line that always counts.
    ///   - recoveriesPerAnswer: How many times one answer goes on after a stop.
    ///   - passTokenLimit: The most output tokens of one generation pass when
    ///     the caller names no ceiling.
    ///   - comparesLineShapes: Whether the detector compares the shape of
    ///     each line, and not its exact text.
    ///   - shortLineRepeatThreshold: How many times one short shape can
    ///     occur in a call before it counts.
    ///   - reasoningTokenLimit: The most reasoning tokens of one generation
    ///     pass, or `nil` or `0` for no limit.
    public init(
        isEnabled: Bool = defaultIsEnabled,
        windowTokens: Int = defaultWindowTokens,
        minimumLineLength: Int = defaultMinimumLineLength,
        recoveriesPerAnswer: Int = defaultRecoveriesPerAnswer,
        passTokenLimit: Int = defaultPassTokenLimit,
        comparesLineShapes: Bool = defaultComparesLineShapes,
        shortLineRepeatThreshold: Int = defaultShortLineRepeatThreshold,
        reasoningTokenLimit: Int? = defaultReasoningTokenLimit
    ) {
        self.isEnabled = isEnabled
        self.windowTokens = windowTokens
        self.minimumLineLength = minimumLineLength
        self.recoveriesPerAnswer = recoveriesPerAnswer
        self.passTokenLimit = passTokenLimit
        self.comparesLineShapes = comparesLineShapes
        self.shortLineRepeatThreshold = shortLineRepeatThreshold
        self.reasoningTokenLimit = reasoningTokenLimit
    }

    /// Decodes the stored form. A stored form from before task ^dzw15st has
    /// no ``passTokenLimit`` key, and it loads with ``defaultPassTokenLimit``.
    /// A stored form from before task ^ez2g5gw has no ``comparesLineShapes``
    /// and no ``shortLineRepeatThreshold`` key, and it loads with
    /// ``defaultComparesLineShapes`` and ``defaultShortLineRepeatThreshold``.
    /// A stored form from before task ^hm9trt5 has no ``reasoningTokenLimit``
    /// key, and it loads with ``defaultReasoningTokenLimit``. A stored `null`
    /// under that key is a `nil` limit: no limit.
    ///
    /// - Parameter decoder: The decoder of the stored form.
    /// - Throws: `DecodingError` when a key other than ``passTokenLimit``,
    ///   ``comparesLineShapes``, ``shortLineRepeatThreshold`` and
    ///   ``reasoningTokenLimit`` is missing, or when a value has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            windowTokens: try container.decode(Int.self, forKey: .windowTokens),
            minimumLineLength: try container.decode(Int.self, forKey: .minimumLineLength),
            recoveriesPerAnswer: try container.decode(Int.self, forKey: .recoveriesPerAnswer),
            passTokenLimit: try container.decodeIfPresent(Int.self, forKey: .passTokenLimit)
                ?? Self.defaultPassTokenLimit,
            comparesLineShapes: try container.decodeIfPresent(Bool.self, forKey: .comparesLineShapes)
                ?? Self.defaultComparesLineShapes,
            shortLineRepeatThreshold: try container.decodeIfPresent(Int.self, forKey: .shortLineRepeatThreshold)
                ?? Self.defaultShortLineRepeatThreshold,
            reasoningTokenLimit: container.contains(.reasoningTokenLimit)
                ? try container.decodeIfPresent(Int.self, forKey: .reasoningTokenLimit)
                : Self.defaultReasoningTokenLimit)
    }

    /// Encodes the stored form. Each key is written, and a `nil`
    /// ``reasoningTokenLimit`` is written as `null`, so it does not load as
    /// ``defaultReasoningTokenLimit``.
    ///
    /// - Parameter encoder: The encoder of the stored form.
    /// - Throws: What the encoder throws.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(windowTokens, forKey: .windowTokens)
        try container.encode(minimumLineLength, forKey: .minimumLineLength)
        try container.encode(recoveriesPerAnswer, forKey: .recoveriesPerAnswer)
        try container.encode(passTokenLimit, forKey: .passTokenLimit)
        try container.encode(comparesLineShapes, forKey: .comparesLineShapes)
        try container.encode(shortLineRepeatThreshold, forKey: .shortLineRepeatThreshold)
        try container.encode(reasoningTokenLimit, forKey: .reasoningTokenLimit)
    }

    /// The shape of `line`, as the detector compares it: the line without
    /// the white space at its two ends and, when ``comparesLineShapes`` is
    /// `true`, with each run of decimal digits replaced by
    /// ``digitRunPlaceholder``.
    ///
    /// - Parameter line: One complete line, without its line feed.
    /// - Returns: The shape of the line.
    func shape(of line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard comparesLineShapes else { return trimmed }
        return trimmed.replacing(#/\d+/#, with: Self.digitRunPlaceholder)
    }

    /// The pass token limit that a session applies: ``passTokenLimit`` when
    /// the detection is enabled, else `nil`.
    var passTokenLimitInForce: Int? {
        isEnabled ? passTokenLimit : nil
    }

    /// The reasoning token limit that a session applies:
    /// ``reasoningTokenLimit`` when the detection is enabled and the limit is
    /// more than zero, else `nil`.
    var reasoningTokenLimitInForce: Int? {
        guard isEnabled, let reasoningTokenLimit, reasoningTokenLimit > 0 else { return nil }
        return reasoningTokenLimit
    }

    /// The words of a stop report for what follows the stop.
    ///
    /// - Parameter recovery: The number of the recovery attempt that
    ///   follows the stop, or `nil` when the answer has no recovery left.
    /// - Returns: The words, for a log line.
    func followingStepDescription(recovery: Int?) -> String {
        recovery.map { "recovery \($0) of \(recoveriesPerAnswer) follows" }
            ?? "no recovery is left, so a final pass with the reasoning off follows"
    }

    /// Each value in force, by name, for a log line.
    var loggedValues: String {
        """
        repetitionDetection: isEnabled = \(isEnabled), windowTokens = \(windowTokens), \
        minimumLineLength = \(minimumLineLength), recoveriesPerAnswer = \(recoveriesPerAnswer), \
        passTokenLimit = \(passTokenLimit), comparesLineShapes = \(comparesLineShapes), \
        shortLineRepeatThreshold = \(shortLineRepeatThreshold), \
        reasoningTokenLimit = \(reasoningTokenLimit.map(String.init) ?? "none")
        """
    }
}

/// A report that the session stopped a generate call because the call no
/// longer wrote new lines, carried by ``SessionEvent/repetitionStopped(_:)``.
///
/// The counts come from the lines that the session read from the reasoning,
/// the text and the tool-call arguments of the call. The tokens are counted
/// with the session's ``TokenCounter``.
public struct RepetitionStop: Sendable, Equatable, CustomStringConvertible {
    /// The tokens the call generated before the stop: the tokens of each
    /// complete line of the reasoning, the text and the tool-call arguments
    /// that the session read, short lines included.
    public let generatedTokens: Int

    /// The lines of the call that count: lines that end with a line feed and
    /// whose shape is at least ``RepetitionDetection/minimumLineLength`` long,
    /// and short lines whose shape occurred more than
    /// ``RepetitionDetection/shortLineRepeatThreshold`` times.
    public let countedLines: Int

    /// The lines that count and that the call did not write before.
    public let newLines: Int

    /// The tokens of the repeated lines since the last new line. At the stop
    /// it is at least ``RepetitionDetection/windowTokens``.
    public let tokensWithoutNewLine: Int

    /// The settings in force for the stop.
    public let detection: RepetitionDetection

    /// The number of the recovery attempt that follows the stop, from 1, or
    /// `nil` when the answer has no recovery left: one final pass with the
    /// reasoning of the model off then follows (task ^0dcsd3t).
    public let recovery: Int?

    /// Creates a report.
    ///
    /// - Parameters:
    ///   - generatedTokens: The tokens the call generated before the stop.
    ///   - countedLines: The lines of the call that count.
    ///   - newLines: The lines that count and that were new.
    ///   - tokensWithoutNewLine: The tokens of the repeated lines since the
    ///     last new line.
    ///   - detection: The settings in force.
    ///   - recovery: The number of the recovery attempt that follows, or `nil`.
    public init(
        generatedTokens: Int,
        countedLines: Int,
        newLines: Int,
        tokensWithoutNewLine: Int,
        detection: RepetitionDetection,
        recovery: Int?
    ) {
        self.generatedTokens = generatedTokens
        self.countedLines = countedLines
        self.newLines = newLines
        self.tokensWithoutNewLine = tokensWithoutNewLine
        self.detection = detection
        self.recovery = recovery
    }

    /// The share of the counted lines that were new, from 0 to 1, or 0 when
    /// no line counted.
    public var newLineShare: Double {
        guard countedLines > 0 else { return 0 }
        return Double(newLines) / Double(countedLines)
    }

    /// The format of ``newLineShare`` in ``description``: three decimals.
    private static let shareFormat = "%.3f"

    /// A one-line rendering of this report, also used as the session's log
    /// line. It names each value of ``detection``.
    public var description: String {
        let share = String(format: Self.shareFormat, newLineShare)
        let next = detection.followingStepDescription(recovery: recovery)
        return """
            the call stopped because it repeats itself: it generated \(generatedTokens) tokens, \
            \(newLines) of \(countedLines) counted lines were new (share \(share)), and no new line \
            came in the last \(tokensWithoutNewLine) tokens; \(next) (\(detection.loggedValues))
            """
    }
}
