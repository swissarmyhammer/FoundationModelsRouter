---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3wg2fw2s6vvnpspbwc0fc73
  text: |-
    Research:
    - `.gitignore` ignores `Package.resolved` (commit c5bd4d69). Git does not track the root file or the `IntegrationTests/Package.resolved` file. Thus this fix changes a local file only. A git diff does not show it.
    - `IntegrationTests/Package.resolved` pins FoundationModelsExtras at `09eed094`. The root file pins `50fd4a5a`.
    - The two files also differ on other pins: mlx-swift-lm (`36a04648` here, `a1f77ad9` at root), swift-collections (1.6.0 here, 1.7.0 at root), swift-jinja (2.4.2 here, 2.5.1 at root). The root file also has swift-libgit2 1.9.7, which this file does not have.
  timestamp: 2026-10-01T19:46:43.714043+00:00
- actor: claude-code
  id: 01m3wgzvtkdpmazxhfwn2zyy4k
  text: |-
    Implementation:
    - Before the change, `swift build --package-path IntegrationTests --build-tests` failed with `no type named 'Mailbox' in module 'FoundationModelsExtras'`.
    - Step 1: I set the FoundationModelsExtras pin to `50fd4a5a` and ran `swift package --package-path IntegrationTests resolve`. SwiftPM kept the pin and added swift-libgit2 1.9.7. The build then failed on a different cause: `type 'MLXLanguageModel' has no member '$promptCacheScope'`. The old mlx-swift-lm pin (`36a04648`) caused this error.
    - Step 2: I set three more pins to the root values: mlx-swift-lm `a1f77ad9`, swift-collections 1.7.0, and swift-jinja 2.5.1. Then I ran `resolve` again. Now the only differences from the root file are `originHash` and the swift-argument-parser location (no `.git` suffix). Each manifest gives its own value for these two items, so they must stay different.
    - The file is gitignored, so `git status` does not show the change.
    - Warning: each build prints the llbuild line `missing creator for mutated node ... mlx-swift_Cmlx.bundle`. A no-op root `swift build --build-tests` prints the same line. It comes from the mlx-swift dependency and not from Swift source. Earlier cards recorded the same line (for example tasks 01M39ZNSNZGBYEY5G8R93KJN94 and 01M1SF78ZQ10C0F2Z5Y8R6ZN8N).
  timestamp: 2026-10-01T20:02:46.227188+00:00
- actor: claude-code
  id: 01m3wgzy6062f0j8r64a67167g
  text: |-
    ### implement — changed
    - evidence: 1 file changed (gitignored): IntegrationTests/Package.resolved. `swift build --package-path IntegrationTests --build-tests`: Build complete, 0 errors. `swift test --package-path IntegrationTests`: 49 tests in 22 suites passed (606 s), and 1 test in 1 suite passed (145 s). Root `swift test`: 1452 tests in 183 suites passed with 2 known issues, 23 tests in 11 suites passed, 19 tests in 3 suites passed. The only warning is the mlx-swift llbuild line `missing creator for mutated node`. The root build prints the same line.
    - next: review
  timestamp: 2026-10-01T20:02:48.640203+00:00
- actor: claude-code
  id: 01m3wh2qg4ra4dkweqfhk9kyad
  text: |-
    ### test — green
    - evidence: swift test (root) — 1452 tests in 183 suites passed, 0 failures, 0 skipped; 2 known issues are withKnownIssue tests that assert an issue is recorded (RealModelHarnessTests, BoundedWaitTests). swift build --package-path IntegrationTests --build-tests — Build complete, exit 0, no compiler warnings.
    - note: SwiftPM prints this line in both builds: "warning: missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS". It is a build-system message about the mlx-swift dependency bundle. It is not a compiler warning, and it is not from this repository's code.
    - next: review. The real-model tests were not rerun (the implementer ran them: 49/22 + 1/1 passed).
  timestamp: 2026-10-01T20:04:20.100457+00:00
position_column: doing
position_ordinal: '80'
title: 'The IntegrationTests package does not build: its Package.resolved pins an old FoundationModelsExtras with no Mailbox'
---
## Problem

`swift build --package-path IntegrationTests --build-tests` fails on `main` with:

```
Sources/FoundationModelsRouter/Session/SessionMessage.swift:14:58: error: no type named 'Mailbox' in module 'FoundationModelsExtras'
```

`IntegrationTests/Package.resolved` pins FoundationModelsExtras at revision `09eed094a1a577171ff4f7fa4dffb021a21be676`. The root `Package.resolved` pins revision `50fd4a5aeac0aede8f4e3d4783946c7afa1af784`, which has `Mailbox`.

Found while task ^hm9trt5 was in work. That task did not change the dependency pins.

## What to do

- Update `IntegrationTests/Package.resolved` so that it resolves the same FoundationModelsExtras revision as the root package.
- Run `swift build --package-path IntegrationTests --build-tests` and make sure it builds with no error and no warning.