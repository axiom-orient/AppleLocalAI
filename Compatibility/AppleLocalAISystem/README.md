# AppleLocalAISystem

A separate Swift 6.2+ package for the Apple system model on iOS 26+ and macOS 26+.
It has no package dependencies and does not import the OS 27 root SDK or optional
backends.

Add this directory as a local Swift package dependency and select the
`AppleLocalAISystem` library product. The package provides one factory:

```swift
import AppleLocalAISystem
import FoundationModels

let session = try AppleLocalAISystem.makeSession(
  model: .default,
  instructions: Instructions("Answer briefly.")
)
let response = try await session.respond(to: "Name one common fruit.")
print(response.content)
```

The factory reads the supplied model's current `availability` before constructing
Apple's native `LanguageModelSession`. When unavailable, it throws
`AppleLocalAISystemError.unavailable` with Apple's original
`SystemLanguageModel.Availability.UnavailableReason`. Inspect that associated
value to distinguish device eligibility, Apple Intelligence settings and model
readiness; future native reasons remain intact.

The returned session is the native Foundation Models session. Use its APIs for
responses, streaming, structured generation, tools and transcript inspection.
There is no additional session, history, cancellation, readiness cache or model
fallback. Availability can change after construction; handle errors from native
generation normally.

The root `AppleLocalAI` package and optional backends retain their OS 27 minimum.
This leaf package supports only `SystemLanguageModel` through the OS 26 API;
it does not backport OS 27 model conformances or dynamic profiles.

Run tests with an isolated build directory:

```sh
swift test --package-path Compatibility/AppleLocalAISystem --scratch-path /tmp/applelocalai-system-tests
```

The normal suite checks every known unavailable reason and conditionally verifies
real native rejection or construction on the host. Session construction does not
prove model inference. Actual inference is opt-in:

```sh
APPLE_LOCAL_AI_SYSTEM_INFERENCE=1 swift test --package-path Compatibility/AppleLocalAISystem --scratch-path /tmp/applelocalai-system-tests --filter nativeSystemInference
```

The inference test explicitly skips when the host system model is unavailable.
An iOS deployment build verifies OS 26 API availability; actual iOS 26 inference
requires a supported device with Apple Intelligence enabled and its model ready.
The Swift tools minimum also permits a matching Xcode 26/macOS 26 test environment;
compilation with an installed Swift 6.2 toolchain has not been verified here.

API references: [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel),
[availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.property),
[LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession).
