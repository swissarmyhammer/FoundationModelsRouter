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
/// name out keeps the cache and transcript directories correct if the target
/// is ever renamed. The telemetry names are in ``RouterTelemetry``.
let moduleName = String(#fileID.prefix { $0 != "/" })
