---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: Label first parameters and complete param/throws docs in LiveModelLoader.swift
---
A review pass on `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` (run after fixing task 01KWVWXHMHR3XM8PM6T5WVXHNK's duplication/doc-period findings) surfaced a new, distinct category of findings — out of scope for that task, which only covered the respond/schema duplication and doc-comment periods:

- [ ] `LiveEmbeddingContainer.embed(_:)` (instance method) — unlabeled first parameter for a non-value-preserving operation. Change to `func embed(texts: [String]) async throws -> [[Float]]`.
- [ ] `LiveEmbeddingContainer.embed(_:in:)` (static) — unlabeled first parameter. Change to `static func embed(texts: [String], in container: EmbedderModelContainer) async throws -> [[Float]]`.
- [ ] `LiveModelLoader.preload(_:)` — unlabeled first parameter. Change to `public func preload(container: any LoadedModelContainer) async throws`. Also missing `- Parameter container:` and `- Throws:` doc lines.
- [ ] `LiveModelLoader.evict(_:)` — unlabeled first parameter. Change to `public func evict(container: any LoadedModelContainer) async`. Also missing `- Parameter container:` doc line.
- [ ] `LiveModelLoader.handler(_:)` (static) — unlabeled first parameter. Change to `static func handler(reporting: @escaping @Sendable (DownloadProgress) -> Void) -> @Sendable (Progress) -> Void`.
- [ ] `UnconfiguredModelLoader.preload(_:)` — missing `- Parameter container:` and `- Throws:` doc lines.

Renaming `preload`/`evict` requires updating the `ModelLoader`/`LoadedModelContainer` protocol declarations (`Sources/FoundationModelsRouter/Resolution/ModelLoader.swift`) plus every conformance and call site (grep for `.preload(` and `.evict(` across `Sources/` and `Tests/`).

Verify `swift build --target FoundationModelsRouter` stays green after the rename. Test-target compilation is separately broken already (task 01KWVWZJMYGB295V9C0QZWTM1M covers that) — do not treat pre-existing test build failures as new regressions, but do relabel any test-double conformances so they don't add a *new* class of failure.