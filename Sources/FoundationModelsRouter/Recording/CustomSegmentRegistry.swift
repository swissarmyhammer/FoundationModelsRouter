import Foundation
import FoundationModels

/// A ``FoundationModels/Transcript/CustomSegment`` conformance the router can
/// rebuild from disk.
///
/// `CustomSegment` guarantees `content: Content` with `Content: Codable`, so
/// *persisting* any custom segment is always possible without help —
/// ``TranscriptEntryMapper/event(from:)`` opens the existential generically
/// and encodes `content` with no registry involved. What the protocol does
/// **not** declare is an initializer, so *rebuilding* a concrete conforming
/// type from its persisted `id` and JSON `content` needs a type that knows
/// how to construct itself from those two pieces. Conform a custom-segment
/// type to this refinement and ``CustomSegmentRegistry/register(_:)`` it to
/// opt it into round-tripping through
/// ``TranscriptEntryMapper/entry(from:kind:registry:)``.
public protocol PersistableCustomSegment: Transcript.CustomSegment {
    /// A stable string identifying this concrete type on disk.
    ///
    /// Defaults to the type's fully-qualified name
    /// (`String(reflecting: Self.self)`) — the same string
    /// ``TranscriptEntryMapper/event(from:)`` writes as the discriminator for
    /// a `.custom` segment whose concrete type does *not* conform to
    /// ``PersistableCustomSegment``, so the default and that fallback always
    /// agree: a type that starts out unregistered and later adopts this
    /// protocol with the default discriminator keeps decoding its own old
    /// recordings.
    static var typeDiscriminator: String { get }

    /// Rebuilds a segment from its persisted `id` and decoded `content`.
    ///
    /// - Parameters:
    ///   - id: The segment's persisted `id`.
    ///   - content: The segment's `content`, decoded from its persisted JSON.
    /// - Throws: If `content` cannot be turned into a valid segment.
    init(id: String, content: Content) throws
}

extension PersistableCustomSegment {
    /// The default discriminator: this type's fully-qualified name.
    public static var typeDiscriminator: String { String(reflecting: Self.self) }
}

/// A registry of concrete ``PersistableCustomSegment`` types, populated by an
/// integrator and passed to ``TranscriptEntryMapper/entry(from:kind:registry:)``
/// so a persisted `.custom` segment can be rebuilt.
///
/// Persisting a `.custom` segment never needs this registry — the
/// `CustomSegment` protocol guarantees `content` is `Codable`, so
/// ``TranscriptEntryMapper/event(from:)`` can always write one out. Only
/// *rebuilding* one needs outside help, because `CustomSegment` declares no
/// initializer: this registry is that help, keyed by
/// ``PersistableCustomSegment/typeDiscriminator``.
public struct CustomSegmentRegistry: Sendable {
    /// Rebuilds a segment from its persisted `id` and content JSON, keyed by
    /// discriminator.
    private var rebuilders: [String: @Sendable (String, String) throws -> Transcript.Segment] = [:]

    /// The fully-qualified name of the type registered under each
    /// discriminator, kept only to name it in ``register(_:)``'s
    /// duplicate-discriminator trap message.
    private var registeredTypeNames: [String: String] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers `type` so a persisted `.custom` segment whose discriminator
    /// is `type.typeDiscriminator` can be rebuilt by
    /// ``TranscriptEntryMapper/entry(from:kind:registry:)``.
    ///
    /// **Traps on a duplicate discriminator.** Registering a second type
    /// under a `typeDiscriminator` that is already registered is a
    /// programmer error — two distinct ``PersistableCustomSegment``
    /// conformances silently aliasing the same on-disk representation is
    /// exactly the kind of ambiguity this design never lets pass silently
    /// elsewhere (every other rebuild failure in ``TranscriptEntryMapper``
    /// throws a typed, descriptive error rather than degrading quietly).
    /// `register` therefore calls `preconditionFailure`, naming both the
    /// discriminator and the already-registered type, rather than silently
    /// overwriting (last-wins) or silently keeping the first registration.
    /// This is a build-time/setup-time registration call, not a per-event
    /// decode path, so a hard trap — not a `throws` — is the right shape: it
    /// fails the integrator's registry setup immediately and loudly, before
    /// any decoding is attempted.
    ///
    /// Not unit-tested: there is no exit-test/trap-testing helper anywhere in
    /// this suite (verified against `Tests/`), and this repo's existing
    /// `preconditionFailure` sites — e.g. `RoutedLLM.makeSession`'s
    /// weak-owning-profile trap — are likewise documented in a doc comment
    /// but not covered by an automated test. This follows that same
    /// precedent rather than introducing a new trap-testing mechanism.
    ///
    /// - Parameter type: The ``PersistableCustomSegment`` conformance to register.
    public mutating func register<S: PersistableCustomSegment>(_ type: S.Type) {
        let discriminator = S.typeDiscriminator
        if let existing = registeredTypeNames[discriminator] {
            preconditionFailure(
                "CustomSegmentRegistry.register: duplicate discriminator \"\(discriminator)\" — "
                    + "already registered by \(existing); cannot also register \(String(reflecting: S.self))"
            )
        }
        registeredTypeNames[discriminator] = String(reflecting: S.self)
        rebuilders[discriminator] = { id, contentJSON in
            let content = try JSONDecoder().decode(S.Content.self, from: Data(contentJSON.utf8))
            return .custom(try S(id: id, content: content))
        }
    }

    /// Rebuilds a `.custom` segment from its persisted discriminator, `id`,
    /// and content JSON.
    ///
    /// - Parameters:
    ///   - discriminator: The persisted type-discriminator string.
    ///   - id: The segment's persisted `id`.
    ///   - contentJSON: The segment's `content`, encoded to JSON.
    /// - Returns: The rebuilt `.custom` segment.
    /// - Throws: ``TranscriptEntryReconstructionError/unregisteredCustomSegmentType(discriminator:)``
    ///   when no type is registered under `discriminator`;
    ///   ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)``
    ///   when `contentJSON` cannot be decoded into the registered type's
    ///   `Content`, or when its `init(id:content:)` throws.
    func rebuildSegment(discriminator: String, id: String, contentJSON: String) throws -> Transcript.Segment {
        guard let rebuilder = rebuilders[discriminator] else {
            throw TranscriptEntryReconstructionError.unregisteredCustomSegmentType(discriminator: discriminator)
        }
        do {
            return try rebuilder(id, contentJSON)
        } catch let error as TranscriptEntryReconstructionError {
            throw error
        } catch {
            throw TranscriptEntryReconstructionError.invalidJSON(
                context: "custom segment \(id) (discriminator \(discriminator)) content",
                underlying: String(describing: error)
            )
        }
    }
}
