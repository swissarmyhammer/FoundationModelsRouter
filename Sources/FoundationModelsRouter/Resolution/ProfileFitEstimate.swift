import Foundation

/// The result of ``Router/estimateFit(of:minimumContextTokens:)``: whether
/// the four slots of a profile fit the memory budget of this machine, and
/// what the fit chose.
///
/// The estimate uses the same sizing and the same joint fit as
/// ``Router/resolve(profile:reporting:)``, against the whole machine budget.
/// The budget does not subtract the models that the pool keeps resident, so
/// one profile gets the same estimate whatever other profiles are loaded. A
/// host uses it to show which profiles this machine can run before the user
/// selects one.
///
/// A profile fits only when the four slots fit with a context window of the
/// minimum (``defaultMinimumContextTokens``) or more (decision D203). A
/// smaller window is not sufficient for a coding session.
public struct ProfileFitEstimate: Sendable, Equatable {
    /// The minimum context window of a fit, in tokens: 32K. A profile whose
    /// largest window that fits is smaller does not fit. When the native
    /// window of the model is smaller, the native window is the minimum.
    public static let defaultMinimumContextTokens = 32_768

    /// Whether one candidate of each of the four slots fits the budget.
    public let fits: Bool

    /// The bytes that the chosen fit charges against the budget, the sum of
    /// the charge of the model of each slot at ``contextTokens``. It is `nil`
    /// when the profile does not fit.
    public let requiredBytes: Int64?

    /// The context window of the chosen fit, in tokens: the largest window
    /// that fits, or the explicit context of the profile. It is `nil` when
    /// the profile does not fit.
    public let contextTokens: Int?

    /// The memory budget of this machine, in bytes. The models in the pool
    /// do not decrease it.
    public let budgetBytes: Int64

    /// The candidate that each slot chose. It is empty when the profile does
    /// not fit.
    public let chosen: [ModelSlot: ModelRef]

    /// The readable reason when the profile does not fit, a candidate could
    /// not be sized, or the task was cancelled. It is `nil` when the profile
    /// fits.
    public let failure: String?

    /// Makes the estimate of a profile that fits.
    ///
    /// - Parameters:
    ///   - requiredBytes: The bytes that the chosen fit charges.
    ///   - contextTokens: The context window of the chosen fit.
    ///   - budgetBytes: The memory budget of this machine.
    ///   - chosen: The candidate that each slot chose.
    init(requiredBytes: Int64, contextTokens: Int, budgetBytes: Int64, chosen: [ModelSlot: ModelRef]) {
        self.fits = true
        self.requiredBytes = requiredBytes
        self.contextTokens = contextTokens
        self.budgetBytes = budgetBytes
        self.chosen = chosen
        self.failure = nil
    }

    /// Makes the estimate of a profile that does not fit.
    ///
    /// - Parameters:
    ///   - failure: The readable reason.
    ///   - budgetBytes: The memory budget of this machine.
    init(failure: String, budgetBytes: Int64) {
        self.fits = false
        self.requiredBytes = nil
        self.contextTokens = nil
        self.budgetBytes = budgetBytes
        self.chosen = [:]
        self.failure = failure
    }

    /// The locale that writes the token counts of a failure, so the text
    /// has the same digit groups on each machine: "32,768".
    private static let countLocale = Locale(identifier: "en_US")

    /// Makes the estimate of a profile whose largest window that fits is
    /// smaller than the minimum window.
    ///
    /// - Parameters:
    ///   - largestWindow: The largest window that fits, in tokens.
    ///   - minimumWindow: The window that a fit needs, in tokens.
    ///   - budgetBytes: The memory budget of this machine.
    init(largestWindow: Int, minimumWindow: Int, budgetBytes: Int64) {
        let largest = largestWindow.formatted(.number.locale(Self.countLocale))
        let minimum = minimumWindow.formatted(.number.locale(Self.countLocale))
        self.init(
            failure: "the largest window that fits is \(largest) tokens; a profile needs \(minimum)",
            budgetBytes: budgetBytes)
    }

    /// The failure of an estimate whose task was cancelled.
    static let cancelledFailure = "the estimate was cancelled"

    /// Makes the estimate of a task that was cancelled before the estimate
    /// was complete.
    ///
    /// - Parameter budgetBytes: The memory budget of this machine.
    /// - Returns: An estimate that does not fit, with ``cancelledFailure``.
    static func cancelled(budgetBytes: Int64) -> ProfileFitEstimate {
        ProfileFitEstimate(failure: cancelledFailure, budgetBytes: budgetBytes)
    }
}
