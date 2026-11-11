import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Proves the rule that tells a local model path from a Hub repo id, and the
/// expansion of the `~` and `./` forms to an absolute path.
@Suite("LocalModelPath")
struct LocalModelPathTests {
    /// A home folder that is not the real one.
    private static let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    /// A working folder that is not the real one.
    private static let workingDirectory = URL(filePath: "/work/project", directoryHint: .isDirectory)

    /// Resolves a reference against the fake home and the fake working folder.
    private static func resolved(_ ref: ModelRef) -> ModelRef {
        LocalModelPath.resolved(ref, home: home, workingDirectory: workingDirectory)
    }

    @Test("an absolute path stays as it is")
    func absolutePathStays() {
        #expect(Self.resolved(ModelRef(repo: "/models/qwen")).repo == "/models/qwen")
    }

    @Test("a path that starts with ~/ is expanded under the home folder")
    func tildeExpands() {
        #expect(Self.resolved(ModelRef(repo: "~/models/qwen")).repo == "/Users/someone/models/qwen")
    }

    @Test("a path that is only ~ is the home folder")
    func bareTildeIsHome() {
        #expect(Self.resolved(ModelRef(repo: "~")).repo == "/Users/someone")
    }

    @Test("a path that starts with ./ is resolved under the working folder")
    func dotSlashResolves() {
        #expect(Self.resolved(ModelRef(repo: "./models/qwen")).repo == "/work/project/models/qwen")
    }

    @Test("a Hub repo id stays as it is")
    func hubIdStays() {
        #expect(Self.resolved(ModelRef(repo: "mlx-community/Qwen3-4B")) == ModelRef(repo: "mlx-community/Qwen3-4B"))
    }

    @Test("a Hub repo id is not a local path")
    func hubIdIsNotLocal() {
        #expect(LocalModelPath.directory(of: "mlx-community/Qwen3-4B", home: Self.home, workingDirectory: Self.workingDirectory) == nil)
    }

    @Test("a plain relative name is not a local path, even when a folder of that name exists")
    func plainRelativeNameIsNotLocal() {
        #expect(LocalModelPath.directory(of: "models", home: Self.home, workingDirectory: Self.workingDirectory) == nil)
    }

    @Test("an absolute path is a local path")
    func absolutePathIsLocal() {
        #expect(LocalModelPath.directory(of: "/models/qwen", home: Self.home, workingDirectory: Self.workingDirectory)?.path == "/models/qwen")
    }

    @Test("the revision of a local reference is kept")
    func revisionKept() {
        #expect(Self.resolved(ModelRef(repo: "./m", revision: "abc")).revision == "abc")
    }

    @Test("the path inside a Hub repository is kept, so a quant folder of a GGUF repo still names one model")
    func hubPathKept() {
        let ref = ModelRef("unsloth/Qwen3-4B-GGUF/Q4_K_M")

        #expect(Self.resolved(ref) == ref)
    }

    @Test("the drafter of a local reference is resolved too")
    func drafterResolved() {
        let ref = ModelRef(repo: "./m", drafter: ModelRef(repo: "~/d"))

        #expect(Self.resolved(ref).drafter?.repo == "/Users/someone/d")
    }

    @Test("a profile definition resolves the local paths of every slot")
    func profileResolvesEverySlot() {
        let profile = ProfileDefinition(
            name: "local", description: "local models",
            standard: [ModelRef(repo: "~/s")], flash: [ModelRef(repo: "./f")], embedding: [ModelRef(repo: "/e")])

        let resolved = profile.resolvingLocalModelPaths(home: Self.home, workingDirectory: Self.workingDirectory)

        #expect(
            [resolved.standard, resolved.flash, resolved.embedding].flatMap { $0.map(\.repo) }
                == ["/Users/someone/s", "/work/project/f", "/e"])
    }

    @Test("a profile definition keeps its decision candidates, with their local paths resolved")
    func profileResolvesTheDecisionCandidates() {
        let profile = ProfileDefinition(
            name: "local", description: "local models",
            standard: [ModelRef(repo: "~/s")], flash: [ModelRef(repo: "./f")], embedding: [ModelRef(repo: "/e")],
            decision: [ModelRef(repo: "~/d"), ModelRef(repo: "org/decider")])

        let resolved = profile.resolvingLocalModelPaths(home: Self.home, workingDirectory: Self.workingDirectory)

        #expect(resolved.decision.map(\.repo) == ["/Users/someone/d", "org/decider"])
    }
}
