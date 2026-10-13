// The mail vocabulary is in FoundationModelsExtras (`mailbox.md`, section 5):
// the canonical definitions are in the `Mail/` folder of that package. This
// file re-exports them under the router's module, so a router user needs no
// `import FoundationModelsExtras`. Each name is a scoped re-export of the
// original declaration, not a typealias, so a file that imports only the
// router can also name a nested type (for example `UserMessageOptions.Mode`)
// in a public declaration.
import FoundationModelsExtras

// The correlation id of one mail.
@_exported import struct FoundationModelsExtras.MailID

// The id of one signal, for example a compaction request.
@_exported import struct FoundationModelsExtras.SignalID

// The work that caused one output event: mail, a signal, or the session.
@_exported import enum FoundationModelsExtras.Origin

// One input message to a session.
@_exported import struct FoundationModelsExtras.Mail

// The content of one mail.
@_exported import enum FoundationModelsExtras.MailBody

// The kind of one mail body, with no payload.
@_exported import enum FoundationModelsExtras.MailKind

// The party that sent one mail.
@_exported import enum FoundationModelsExtras.MailSender

// The generation options of one user message.
@_exported import struct FoundationModelsExtras.UserMessageOptions

// A party that takes mail.
@_exported import protocol FoundationModelsExtras.MailSink

// The output events of one mail.
@_exported import struct FoundationModelsExtras.MailSubscription

// Why a mail sink refused a mail.
@_exported import enum FoundationModelsExtras.MailRefusal
