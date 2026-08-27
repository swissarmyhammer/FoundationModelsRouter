import os

/// Module marker for the FoundationModelsRouter package.
///
/// This is the root module of the router. The real surface area lands in the
/// subdirectories the plan lays out — `Core/`, `Sizing/`, `Resolution/`,
/// `Session/`, `Concurrency/`, `Guided/`, and `Recording/`. This file exists so
/// the target has a source to compile from the first commit and gives the
/// bootstrap smoke test a trivial fact to anchor on.
///
/// The compiler supplies the name. `#fileID` expands to
/// `"<ModuleName>/<FileName>.swift"`, so the text before the first `/` is the
/// module this file compiles into. Reading it here rather than writing the
/// name out keeps the `os.Logger` subsystem and the cache and transcript
/// directories correct if the target is ever renamed.
let moduleName = String(#fileID.prefix { $0 != "/" })

/// Creates an ``os/Logger`` scoped to this module's subsystem.
///
/// Every logger in this module reports under the same ``moduleName``
/// subsystem, differing only by category; call sites across the module used
/// to repeat the `Logger(subsystem:category:)` construction verbatim, so this
/// factors out that repetition to a single place.
///
/// - Parameter category: The logger's category (e.g. `"Recording"`,
///   `"Manifest"`).
/// - Returns: A logger for `category` under ``moduleName``.
func makeModuleLogger(category: String) -> Logger {
    Logger(subsystem: moduleName, category: category)
}
