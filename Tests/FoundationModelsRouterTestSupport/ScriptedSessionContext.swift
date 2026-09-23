/// The small, known context window that a test states when it wants one.
///
/// The library has no default context: a profile that names no `context:`
/// uses the window of its model. A scripted session has no real model, and a
/// test that checks a fill fraction or a ceiling needs a known window. Such a
/// test states this one number. The number lives in the tests only.
///
/// This module is the home for the number, because the unit suite and the
/// real-model suite in `IntegrationTests` both link it, and SwiftPM cannot
/// share source between two test targets.
public enum ScriptedSessionContext {
    /// The window, in tokens, that a test states for a scripted session.
    public static let tokens = 8192
}
