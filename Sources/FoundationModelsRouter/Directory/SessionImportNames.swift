import Foundation
import FoundationModelsExtras

/// The names that the imports of a ``RouterSessionDirectory`` hold while
/// their writes run (D209 (h)), so two imports with the same title in the
/// same folder do not get the same name.
///
/// An import reads the live and the recorded sessions before it chooses its
/// name, and it writes its recording after. A second import can choose its
/// name while the first write runs, and the list does not show the first
/// session before its write ends. Thus each import holds its name from the
/// choice to the end of the import:
///
/// - While the write runs, the reservation holds the name. The reservation
///   protects the name only while the import runs.
/// - When the import ends, with a session or with an error, the name goes.
///   After the release, the list shows the imported session only when the
///   recording root of the import is a root of the host
///   (``RouterSessionDirectory/useRecordingRoots(_:)``) or the directory
///   has a usage store (``RouterSessionDirectory/use(usageStore:)``): the
///   directory then records the recording root of the import in the usage
///   store before the release
///   (``RouterSessionDirectory/importSession(_:transcript:)``). With no
///   usage store and a recording root that the host does not give, the
///   list does not show the session, and a later import with the same
///   title in the same folder can get the same name.
///
/// The directory changes the names on its actor. A choice reads the
/// recorded sessions and holds its name with no suspension point between
/// the read and the reservation, and an import records its recording root
/// and releases its name with no suspension point between them. Thus, when
/// the list shows the session of an import after the release, a choice
/// sees each other import either by its reservation or by its session.
struct SessionImportNames {
    /// One name that an import holds.
    private struct Reservation {
        /// The id of the reservation.
        let token: ULID

        /// The comparable path of the working folder of the import
        /// (``RouterSessionDirectory/comparablePath(of:)``).
        let folder: String

        /// The slug of the name.
        let slug: String
    }

    /// The names that the imports hold, in no order.
    private var reservations: [Reservation] = []

    /// Chooses the name of an import with `title` in `folder`
    /// (``SessionDefaultTitle/makeImport(from:in:among:reserved:)``), and
    /// holds it.
    ///
    /// - Parameters:
    ///   - title: The title of the import request.
    ///   - folder: The working folder of the import.
    ///   - summaries: The summaries of the live and the recorded sessions.
    /// - Returns: The name and the token of its reservation, for
    ///   ``release(_:)``.
    mutating func reserve(
        from title: String, in folder: URL, among summaries: [SessionSummary]
    ) -> (name: String, token: ULID) {
        let path = RouterSessionDirectory.comparablePath(of: folder)
        let reserved = Set(reservations.filter { $0.folder == path }.map(\.slug))
        let name = SessionDefaultTitle.makeImport(from: title, in: folder, among: summaries, reserved: reserved)
        let token = ULID.generate()
        reservations.append(Reservation(token: token, folder: path, slug: SessionSlug.make(from: name)))
        return (name, token)
    }

    /// Releases the name of the import that holds `token`, at the end of
    /// that import.
    ///
    /// - Parameter token: The token that ``reserve(from:in:among:)`` gave.
    mutating func release(_ token: ULID) {
        reservations.removeAll { $0.token == token }
    }
}
