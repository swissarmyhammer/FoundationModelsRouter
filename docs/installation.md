# Installation details

The package needs macOS 27 or later. Declare that floor in your `Package.swift`:

```swift
platforms: [.macOS("27.0")],
```

SwiftPM applies macOS 12.0 when your manifest states no floor. The build then
fails.

Add the package to the `dependencies` list in `Package.swift`:

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsRouter", branch: "main"),
```

Then link its product from your own target:

```swift
.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter"),
```

## Hugging Face

`LiveModelLoader` downloads through the Hugging Face client that
`FoundationModelsExtras` links. Your target needs no Hugging Face product of its
own, unless it names `TokenProvider` (see below); then it links the
`HuggingFace` product of `swift-huggingface`.

To keep the models in a folder of your app, give the folder to
`LiveModelLoader(cacheDirectory:)`. Each download goes into that folder, also
when `HF_HOME` names a different folder. With no folder, the loader uses the
default Hugging Face cache. The router keeps its sizing metadata in a different
folder: give that folder to `Router(cacheDir:)`. `Router.cacheDirectory` shows
the folder the router uses.

The downloads and the sizing requests send the Hugging Face token of
`HF_TOKEN` or `~/.cache/huggingface/token` by default. An app with its own home
gives one `TokenProvider` to both, so it does not depend on the folder of the
user:

```swift
let token: TokenProvider = .custom { try? String(contentsOf: tokenFile, encoding: .utf8) }
let router = Router(
    metadataSource: HuggingFaceMetadataSource(tokenProvider: token),
    loader: LiveModelLoader(tokenProvider: token))
```
