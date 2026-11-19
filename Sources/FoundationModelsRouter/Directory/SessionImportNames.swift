import Foundation
import FoundationModelsExtras

/// The names that the imports of a ``RouterSessionDirectory`` hold
/// (D209 (h)), so two imports with the same title in the same folder do not
/// get the same name.
///
/// An import reads the live and the recorded sessions before it chooses its
/// name, and it writes its recording after. A second import can read the
/// recorded sessions before the first write ends, or while it ends. Thus
/// each import holds its name from the choice:
///
/// - While the write runs, the name has no session id.
/// - When the write ends, the name gets the id of the new session. It stays
///   until a later choice reads a summary of that id: from then on, the
///   summary holds the name, and it holds it only while the session is not
///   archived.
/// - When the write fails, the name goes.
///
/// The directory changes the names on its actor, with no suspension point
/// between a choice and its reservation.
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

        /// The id of the imported session, or `nil` while the write runs.
        var sessionID: ULID?
    }

    /// The names that the imports hold, in no order.
    private var reservations: [Reservation] = []

    /// Chooses the name of an import with `title` in `folder`
    /// (``SessionDefaultTitle/makeImport(from:in:among:reserved:)``), and
    /// holds it.
    ///
    /// A name of an ended import whose session `summaries` shows goes first:
    /// the summary now holds it.
    ///
    /// - Parameters:
    ///   - title: The title of the import request.
    ///   - folder: The working folder of the import.
    ///   - summaries: The summaries of the live and the recorded sessions.
    /// - Returns: The name and the token of its reservation, for
    ///   ``finish(_:as:)``.
    mutating func reserve(
        from title: String, in folder: URL, among summaries: [SessionSummary]
    ) -> (name: String, token: ULID) {
        let shown = Set(summaries.map(\.id))
        reservations.removeAll { $0.sessionID.map(shown.contains) ?? false }
        let path = RouterSessionDirectory.comparablePath(of: folder)
        let reserved = Set(reservations.filter { $0.folder == path }.map(\.slug))
        let name = SessionDefaultTitle.makeImport(from: title, in: folder, among: summaries, reserved: reserved)
        let token = ULID.generate()
        reservations.append(Reservation(token: token, folder: path, slug: SessionSlug.make(from: name)))
        return (name, token)
    }

    /// Ends the write of the import that holds `token`: the name gets the id
    /// of the new session, or goes when the write failed.
    ///
    /// - Parameters:
    ///   - token: The token that ``reserve(from:in:among:)`` gave.
    ///   - id: The id of the imported session, or `nil` when the write
    ///     failed.
    mutating func finish(_ token: ULID, as id: ULID?) {
        guard let id else {
            reservations.removeAll { $0.token == token }
            return
        }
        guard let index = reservations.firstIndex(where: { $0.token == token }) else { return }
        reservations[index].sessionID = id
    }
}
