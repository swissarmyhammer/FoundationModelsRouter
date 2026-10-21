import Foundation
import Testing

/// Pins the direction of the dependency between Router and the ACP packages.
/// The ACP agent imports Router, and Router owns the record of past sessions
/// (D72), so no Router source may import a `FoundationModelsACP` module: such
/// an import would make a cycle, and would put the protocol layer under the
/// layer it builds on.
///
/// The suite reads the source files with `FileManager` and runs no shell
/// command.
@Suite("Router imports no ACP module")
struct RouterImportsNoACPTests {
    /// The module name prefix of every ACP package of the family.
    private static let acpModulePrefix = "FoundationModelsACP"

    /// Matches one import line of an ACP module, with or without an
    /// attribute (`@testable`, `@_exported`) or an access modifier before
    /// it, and with or without an import kind (`import struct`). A computed
    /// member, because `Regex` is not `Sendable` and a stored `static let`
    /// of it does not compile under Swift 6.
    private static var acpImportPattern: Regex<Substring> {
        #/^\s*(?:@\w+\s+)*(?:\w+\s+)?import\s+(?:\w+\s+)?FoundationModelsACP\w*/#.anchorsMatchLineEndings()
    }

    /// The repository root, resolved from this file's own path by
    /// ``RepositoryRoot/url(from:)``.
    private static let repositoryRoot = RepositoryRoot.url()

    @Test("no file under Sources/FoundationModelsRouter imports a FoundationModelsACP module")
    func noLibrarySourceImportsAnACPModule() throws {
        let files = try LibrarySourceFiles.urls(under: Self.repositoryRoot)

        let importing = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8).contains(Self.acpImportPattern)
        }

        #expect(
            importing.isEmpty,
            "these files import a \(Self.acpModulePrefix) module: \(importing.map(\.lastPathComponent))")
    }

    @Test("the import pattern matches each spelling of an ACP import")
    func theImportPatternMatchesEachSpelling() {
        let spellings = [
            "import FoundationModelsACPAgent",
            "@testable import FoundationModelsACP",
            "public import FoundationModelsACPClient",
            "@_exported import struct FoundationModelsACPAgent.SessionIndex",
        ]

        for spelling in spellings {
            #expect(spelling.contains(Self.acpImportPattern), "\(spelling) is not matched")
        }
        #expect(!"import FoundationModelsRouter".contains(Self.acpImportPattern))
    }
}
