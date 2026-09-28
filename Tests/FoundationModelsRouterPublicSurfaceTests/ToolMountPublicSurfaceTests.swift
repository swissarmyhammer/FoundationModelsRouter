import Foundation
import Testing

import FoundationModelsRouter

/// Holds ``ToolMount`` and ``ToolMountError`` to the public surface of the
/// router (task ^cs9w81q).
///
/// This target imports only the router module, with a plain import. The router
/// re-exports the Extras declaration of `ToolMount`, so a router user writes
/// `ToolMount` and its nested `ToolMount.Mode` with no import of
/// FoundationModelsExtras, also in a public declaration. The compiler is the
/// first assertion: when the re-export goes, ``MountDeclaringTool`` does not
/// compile.
@Suite("ToolMount and ToolMountError over a plain router import")
struct ToolMountPublicSurfaceTests {
    /// The tool name that the timeout error names.
    private static let toolName = "mount-probe"

    /// The timeout of the probe mount, in seconds.
    private static let timeoutSeconds: TimeInterval = 5

    /// A mount made through the router name keeps the mode and the timeout
    /// that the caller gives.
    @Test("a mount keeps its mode and its timeout")
    func aMountKeepsItsModeAndTimeout() {
        let mount = ToolMount(mode: .background, timeout: Self.timeoutSeconds)

        #expect(mount.mode == .background)
        #expect(mount.timeout == Self.timeoutSeconds)
        #expect(ToolMount.synchronous.mode == .runToCompletion)
        #expect(ToolMount.synchronous.timeout == nil)
    }

    /// A public member that names `ToolMount.Mode` reads the mode of the mount.
    @Test("a public member reads the mode of the mount through the nested router name")
    func aPublicMemberReadsTheModeOfTheMount() {
        let tool = MountDeclaringTool(mount: ToolMount(mode: .background))

        #expect(tool.mode == .background)
        #expect(MountDeclaringTool(mount: nil).mode == nil)
    }

    /// A timeout error made through the router name tells the model the tool
    /// and the timeout.
    @Test("a timeout error names the tool and the timeout")
    func aTimeoutErrorNamesTheToolAndTheTimeout() {
        let error: ToolMountError = .timedOut(tool: Self.toolName, timeoutSeconds: Self.timeoutSeconds)

        #expect(error.description == "mount-probe timed out after 5.0 seconds with no progress")
    }
}

/// A public type that names `ToolMount` and `ToolMount.Mode` in its public
/// members, as a background tool of a router user does. It is public, and at
/// the top level, only because a public declaration is what the suite checks:
/// with a plain typealias, the compiler rejects `ToolMount.Mode` in a public
/// member, because the file does not import FoundationModelsExtras.
public struct MountDeclaringTool {
    /// The mount of the tool.
    public let mount: ToolMount?

    /// The mode of the mount, or `nil` when the tool has no mount.
    public var mode: ToolMount.Mode? { mount?.mode }

    /// Makes a tool with a mount.
    ///
    /// - Parameter mount: The mount of the tool.
    public init(mount: ToolMount?) {
        self.mount = mount
    }
}
