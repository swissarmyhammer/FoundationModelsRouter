import Foundation

extension TranscriptEvent {
    /// The prompt body of a ``TranscriptEvent/Kind/prompt`` event: the text
    /// that the session was asked, without the mail that the submission
    /// delivered with it.
    ///
    /// The text of a prompt event is the render of the delivered mail, then
    /// the text of the session
    /// (``ContextRenderer/promptText(delivering:followedBy:)``). The entry
    /// carries one mail record for each delivered mail
    /// (``TranscriptEvent/mailRecords``). So the body is read in three ways:
    ///
    /// - No delivered mail: the text as recorded.
    /// - Delivered user-type mail (``Mail/isUserMail``): the text of that
    ///   mail, because a submission with user-type mail has no other prompt
    ///   text. Run mail and catalog notices are not part of it.
    /// - Other delivered mail: the text after the render of that mail, or
    ///   `nil` when nothing follows the render.
    ///
    /// The cut of the render works on UTF-8 bytes, so the body keeps every
    /// byte of the text as recorded.
    ///
    /// - Returns: The body, or `nil` when the event has no text or the
    ///   submission has no prompt text of its own.
    var promptBody: String? {
        guard let text else { return nil }
        let delivered = mailRecords.compactMap { record -> Mail? in
            guard case .mailDelivered(let mail) = record else { return nil }
            return mail
        }
        guard !delivered.isEmpty else { return text }
        let userBlocks = delivered.filter(\.isUserMail).compactMap(\.promptText)
        guard userBlocks.isEmpty else { return userBlocks.joined(separator: ContextRenderer.blockSeparator) }
        let mailRender = ContextRenderer.promptText(delivering: delivered, followedBy: nil)
        let renderBytes = Array((mailRender + ContextRenderer.blockSeparator).utf8)
        guard text.utf8.starts(with: renderBytes) else { return nil }
        return String(decoding: text.utf8.dropFirst(renderBytes.count), as: UTF8.self)
    }
}
