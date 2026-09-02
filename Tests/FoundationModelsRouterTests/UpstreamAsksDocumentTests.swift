import Foundation
import FoundationModelsRouterTestSupport
import Testing

/// Pins `UPSTREAM_ASKS.md` to its answered shape. Each `## Ask` heading has
/// an `**Answer:**` paragraph below it, and that paragraph names at least one
/// backticked symbol that the library source under
/// `Sources/FoundationModelsRouter` declares.
///
/// The ACP agent reads the new surface from this file alone. A symbol that
/// the source does not declare is a broken pointer, so this suite reads the
/// source files with `FileManager` and searches them for each name. It runs
/// no shell command.
///
/// A later edit that removes an answer, or that names a symbol the source
/// no longer holds, fails this suite.
@Suite("Upstream asks document")
struct UpstreamAsksDocumentTests {
    /// One ask: its heading line and the lines below it, up to the next
    /// heading of the same level.
    private struct AskSection {
        /// The `## Ask ...` heading line.
        let heading: String
        /// The non-empty lines below the heading, in file order.
        let body: [String]
    }

    /// The prefix of each heading this suite reads as one ask.
    private static let askHeadingPrefix = "## Ask"

    /// The prefix of each heading that ends an ask's body.
    private static let sectionHeadingPrefix = "## "

    /// The text an answer paragraph starts with.
    private static let answerMarker = "**Answer:**"

    /// The path extension of each library source file the search reads.
    private static let sourceFileExtension = "swift"

    /// The path of the asks document, relative to the repository root.
    private static let documentPath = "UPSTREAM_ASKS.md"

    /// The path of the library source tree, relative to the repository root.
    private static let librarySourcePath = "Sources/FoundationModelsRouter"

    /// Matches one backticked span and captures the text inside it. A
    /// computed member, because `Regex` is not `Sendable` and a stored
    /// `static let` of it does not compile under Swift 6.
    private static var backtickedSpan: Regex<(Substring, Substring)> { #/`([^`]+)`/# }

    /// Matches one whole Swift identifier. Computed for the same reason as
    /// ``backtickedSpan``.
    private static var identifierPattern: Regex<Substring> { #/[A-Za-z_][A-Za-z0-9_]*/# }

    /// The repository root, resolved relative to this source file's own path
    /// (`#filePath` is `Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift`,
    /// two directories below the root). Keep this file directly inside
    /// `Tests/FoundationModelsRouterTests/`, or adjust the step count to match
    /// the new location.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/FoundationModelsRouterTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repository root

    @Test("every Ask heading is followed by an Answer paragraph")
    func everyAskHasAnAnswer() throws {
        let sections = try Self.askSections()
        try #require(!sections.isEmpty, "\(Self.documentPath) holds no `\(Self.askHeadingPrefix)` heading.")

        for section in sections {
            #expect(
                Self.answerParagraph(in: section) != nil,
                "\"\(section.heading)\" has no paragraph that starts with \(Self.answerMarker)."
            )
        }
    }

    @Test("every Answer paragraph names a symbol the library source declares")
    func everyAnswerNamesADeclaredSymbol() throws {
        let sections = try Self.askSections()
        try #require(!sections.isEmpty, "\(Self.documentPath) holds no `\(Self.askHeadingPrefix)` heading.")
        let source = try Self.librarySourceText()

        for section in sections {
            let paragraph = try #require(
                Self.answerParagraph(in: section),
                "\"\(section.heading)\" has no paragraph that starts with \(Self.answerMarker)."
            )
            let identifiers = Self.symbolIdentifiers(in: paragraph)
            #expect(
                identifiers.contains { Self.declares(source, identifier: $0) },
                """
                The answer to "\(section.heading)" names no symbol that \(Self.librarySourcePath) declares. \
                Backticked identifiers: \(identifiers)
                """
            )
        }
    }

    /// Reads `UPSTREAM_ASKS.md` and splits it into one section for each
    /// `## Ask` heading. The split is ``TextFileLines/read(from:)``, so this
    /// suite holds no copy of it.
    ///
    /// - Returns: The ask sections, in file order.
    /// - Throws: An error when the document cannot be read.
    private static func askSections() throws -> [AskSection] {
        let document = repositoryRoot.appendingPathComponent(documentPath, isDirectory: false)
        let lines = try TextFileLines.read(from: document)
        let headingIndices = lines.indices.filter { lines[$0].hasPrefix(askHeadingPrefix) }
        return headingIndices.map { headingIndex in
            let below = lines[(headingIndex + 1)...]
            let body = below.prefix { !$0.hasPrefix(sectionHeadingPrefix) }
            return AskSection(heading: lines[headingIndex], body: Array(body))
        }
    }

    /// Finds the answer paragraph of `section`: the first line of its body
    /// that starts with ``answerMarker``.
    ///
    /// - Parameter section: The ask to search.
    /// - Returns: The paragraph, or `nil` when the ask has no answer.
    private static func answerParagraph(in section: AskSection) -> String? {
        section.body.first { $0.hasPrefix(answerMarker) }
    }

    /// Extracts the identifier each backticked span of `paragraph` names.
    ///
    /// A span such as `SessionEvent.elicitationRequested(OperationEvent)`
    /// gives `elicitationRequested`: the text before the first `(`, then its
    /// last dot-separated component. A span that holds a `/` is a file path,
    /// and a span that starts with `.` is a case shorthand; both give
    /// nothing.
    ///
    /// - Parameter paragraph: The answer paragraph to read.
    /// - Returns: The identifiers, in paragraph order.
    private static func symbolIdentifiers(in paragraph: String) -> [String] {
        paragraph.matches(of: backtickedSpan).compactMap { match in
            identifier(fromSymbolName: match.output.1)
        }
    }

    /// Reduces one backticked symbol name to the identifier a source search
    /// can find.
    ///
    /// - Parameter name: The text inside the backticks.
    /// - Returns: The identifier, or `nil` when `name` is a path, a case
    ///   shorthand, or text that is not an identifier.
    private static func identifier(fromSymbolName name: Substring) -> String? {
        let isPathOrShorthand = name.contains("/") || name.hasPrefix(".")
        let beforeArguments = name.prefix { $0 != "(" }
        let lastComponent = beforeArguments.split(separator: ".").last ?? beforeArguments
        let wholeIdentifier = lastComponent.wholeMatch(of: identifierPattern).map { String($0.output) }
        return isPathOrShorthand ? nil : wholeIdentifier
    }

    /// Reads every Swift file under `Sources/FoundationModelsRouter`, at any
    /// depth, and joins them into one text.
    ///
    /// - Returns: The joined source text.
    /// - Throws: An expectation failure when the tree cannot be enumerated
    ///   or holds no Swift file, or an error when a file cannot be read.
    private static func librarySourceText() throws -> String {
        let sourceRoot = repositoryRoot.appendingPathComponent(librarySourcePath, isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil),
            "the source tree at \(sourceRoot.path) cannot be enumerated"
        )
        let files = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == sourceFileExtension }
        try #require(!files.isEmpty, "the source tree at \(sourceRoot.path) holds no Swift file")
        return try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Tells whether `source` holds `identifier` as a whole word.
    ///
    /// - Parameters:
    ///   - source: The joined library source text.
    ///   - identifier: The identifier to find.
    /// - Returns: `true` when the word is there.
    private static func declares(_ source: String, identifier: String) -> Bool {
        source.range(of: "\\b\(identifier)\\b", options: .regularExpression) != nil
    }
}
