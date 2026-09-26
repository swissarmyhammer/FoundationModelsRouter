import Foundation

/// The settings of the detector that stops a generate call that repeats
/// itself (task ^1hcwaqy).
///
/// A reasoning model can write the lines that it already wrote again, in a
/// different sequence, until the call reaches its ceiling. The share of new
/// lines then goes to zero and stays there. The session reads the reasoning
/// and the text of the call in flight, line by line. When one window of
/// generated tokens holds no new line, the session stops the call, keeps the
/// repeated part out of the render that the model receives next, and runs
/// one more submission of the same answer with a short prompt that tells the
/// model to act.
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

    /// Whether the session watches the calls of its submissions. When `false`, no
    /// call stops for repetition.
    public var isEnabled: Bool

    /// The window, in generated tokens, that must hold at least one new
    /// line. Only the tokens of the lines that count and that repeat fill
    /// the window. A new line empties it. When it is full, the call stops.
    public var windowTokens: Int

    /// The minimum length, in characters, of a line that counts. The length
    /// is measured without the white space at the two ends. A shorter line
    /// is neither new nor repeated, so lines that repeat by nature (```,
    /// `"""`, `)`, `...`) never stop a call.
    public var minimumLineLength: Int

    /// How many times one answer goes on after a repetition stop. An answer
    /// is the chain of submissions from the first delivery to the final
    /// answer, so a continuation submission does not reset the count. A stop
    /// after the last recovery ends the answer.
    ///
    /// The key of this value in a stored `session.json` is
    /// `recoveriesPerTurn`, the name of the property before the rename, so
    /// an old recording loads (``CodingKeys``).
    public var recoveriesPerAnswer: Int

    /// The keys of the stored form. Each key is the name of its property,
    /// except ``recoveriesPerAnswer``: its key stays `recoveriesPerTurn`, and
    /// the schema version does not change (`generation-queue.md`, section 5.6).
    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case windowTokens
        case minimumLineLength
        case recoveriesPerAnswer = "recoveriesPerTurn"
    }

    /// Creates the settings. Each parameter defaults to its named default.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the session watches the calls of its submissions.
    ///   - windowTokens: The window, in generated tokens, that must hold at
    ///     least one new line.
    ///   - minimumLineLength: The minimum length of a line that counts.
    ///   - recoveriesPerAnswer: How many times one answer goes on after a stop.
    public init(
        isEnabled: Bool = defaultIsEnabled,
        windowTokens: Int = defaultWindowTokens,
        minimumLineLength: Int = defaultMinimumLineLength,
        recoveriesPerAnswer: Int = defaultRecoveriesPerAnswer
    ) {
        self.isEnabled = isEnabled
        self.windowTokens = windowTokens
        self.minimumLineLength = minimumLineLength
        self.recoveriesPerAnswer = recoveriesPerAnswer
    }

    /// Each value in force, by name, for a log line.
    var loggedValues: String {
        """
        repetitionDetection: isEnabled = \(isEnabled), windowTokens = \(windowTokens), \
        minimumLineLength = \(minimumLineLength), recoveriesPerAnswer = \(recoveriesPerAnswer)
        """
    }
}

/// A report that the session stopped a generate call because the call no
/// longer wrote new lines, carried by ``SessionEvent/repetitionStopped(_:)``.
///
/// The counts come from the lines that the session read from the reasoning
/// and the text of the call. The tokens are counted with the session's
/// ``TokenCounter``.
public struct RepetitionStop: Sendable, Equatable, CustomStringConvertible {
    /// The tokens the call generated before the stop: the tokens of each
    /// complete line of the reasoning and the text that the session read,
    /// short lines included.
    public let generatedTokens: Int

    /// The lines of the call that count: lines that end with a line feed and
    /// that are at least ``RepetitionDetection/minimumLineLength`` long.
    public let countedLines: Int

    /// The lines that count and that the call did not write before.
    public let newLines: Int

    /// The tokens of the repeated lines since the last new line. At the stop
    /// it is at least ``RepetitionDetection/windowTokens``.
    public let tokensWithoutNewLine: Int

    /// The settings in force for the stop.
    public let detection: RepetitionDetection

    /// The number of the recovery attempt that follows the stop, from 1, or
    /// `nil` when the answer has no recovery left and ends.
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
        let next = recovery.map { "recovery \($0) of \(detection.recoveriesPerAnswer) follows" }
            ?? "no recovery is left, so the answer ends"
        return """
            the call stopped because it repeats itself: it generated \(generatedTokens) tokens, \
            \(newLines) of \(countedLines) counted lines were new (share \(share)), and no new line \
            came in the last \(tokensWithoutNewLine) tokens; \(next) (\(detection.loggedValues))
            """
    }
}
