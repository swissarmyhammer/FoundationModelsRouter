import Foundation

/// The result of ``Router/estimateFit(of:)``: whether the four slots of a
/// profile fit the memory budget of this machine, and what the fit chose.
///
/// The estimate uses the same sizing and the same joint fit as
/// ``Router/resolve(profile:reporting:)``, against the whole machine budget.
/// The budget does not subtract the models that the pool keeps resident, so
/// one profile gets the same estimate whatever other profiles are loaded. A
/// host uses it to show which profiles this machine can run before the user
/// selects one.
public struct ProfileFitEstimate: Sendable, Equatable {
    /// Whether one candidate of each of the four slots fits the budget.
    public let fits: Bool

    /// The bytes that the chosen fit charges against the budget, the sum of
    /// the charge of the model of each slot. It is `nil` when the profile
    /// does not fit.
    public let requiredBytes: Int64?

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
    ///   - budgetBytes: The memory budget of this machine.
    ///   - chosen: The candidate that each slot chose.
    init(requiredBytes: Int64, budgetBytes: Int64, chosen: [ModelSlot: ModelRef]) {
        self.fits = true
        self.requiredBytes = requiredBytes
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
        self.budgetBytes = budgetBytes
        self.chosen = [:]
        self.failure = failure
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
