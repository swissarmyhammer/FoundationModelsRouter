import FoundationModels

/// A `Tool` that observes the submission boundary of a session: the point
/// after the session takes its waiting messages and before the model call of
/// a submission.
///
/// A submission is one SDK call. The session calls ``submissionWillBegin()``
/// one time before each submission: before the first submission of an answer,
/// also when only mail started it, and before each continuation submission of
/// that answer.
///
/// A host finds submission-boundary tools with
/// `tool as? any SubmissionBoundaryTool`. The protocol declares no associated
/// types, so that cast succeeds on an `any Tool` existential.
///
/// The hook carries no arguments and no return value: it is a clock tick a
/// tool uses to apply a change it prepared at the side (for example, swapping
/// in a rendered surface it rebuilt out of band), not an event route.
public protocol SubmissionBoundaryTool: Tool {
    /// The session calls this one time before each submission, after it
    /// takes the waiting messages and before the model call of the
    /// submission.
    func submissionWillBegin() async
}
