---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
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