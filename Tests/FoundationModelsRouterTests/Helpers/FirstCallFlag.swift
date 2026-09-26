import Synchronization

/// A flag that exactly one caller takes.
///
/// A scripted model calls a mounted tool in each submission. Under the pump
/// of a session (task ^3qx0mpt), the terminal of each background run is mail
/// that starts one more submission, so a background tool that starts new work
/// on each call would start submissions with no end. A fixture tool takes this
/// flag, and starts its work on the first call only.
final class FirstCallFlag: Sendable {
    /// Whether a caller already took the flag.
    private let taken = Atomic<Bool>(false)

    /// Takes the flag.
    ///
    /// - Returns: `true` for the first caller only.
    func take() -> Bool {
        !taken.exchange(true, ordering: .sequentiallyConsistent)
    }
}
