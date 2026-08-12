import Foundation
import OSLog
import Testing

@testable import FoundationModelsRouter

/// Asserts this process logged, since `start`, a message under this module's
/// subsystem containing `fragment` — proof a degradation warning or an
/// encode-failure fault actually reached the log, read back through
/// `OSLogStore(scope: .currentProcessIdentifier)`.
///
/// Shared by every suite that pins a loud log signal (e.g.
/// `TranscriptEntryMapperTests`' degradation warnings and
/// `TranscriptReconstructionTests`' duplicate-entry-id warning), so the
/// OSLog read-back lives in exactly one place.
///
/// - Parameters:
///   - fragment: The message fragment the log must contain.
///   - start: The instant to read log entries from — capture `Date()` before
///     the code under test runs.
func assertLogged(containing fragment: String, since start: Date) throws {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let entries = try store.getEntries(at: store.position(date: start))
        .compactMap { $0 as? OSLogEntryLog }
        .filter { $0.subsystem == moduleName }
    #expect(
        entries.contains { $0.composedMessage.contains(fragment) },
        "no \(moduleName) log entry since \(start) contains \"\(fragment)\""
    )
}
