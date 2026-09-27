import FoundationModels

@testable import FoundationModelsRouter

extension MessageID {
    /// A fresh message id that no session knows.
    ///
    /// The initializer of ``MessageID`` is internal to FoundationModelsExtras,
    /// so a test cannot make an id directly. This function posts one empty
    /// message to a new mailbox that nothing else uses, and gives the id of
    /// that message. No session holds that mailbox, so a session that gets
    /// this id finds no message for it.
    ///
    /// - Returns: An id that names no message of any session.
    static func unposted() -> MessageID {
        SessionMessageMailbox().post(
            SessionMessage(prompt: .plainText(""), requestedMaxTokens: nil, reader: .reply, serviceContext: nil)
        ).id
    }
}
