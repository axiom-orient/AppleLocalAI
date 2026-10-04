# Platform integration

이 문서는 SwiftPM root와 선택 호환 leaf의 경계·backend별 플랫폼 책임을 정의한다.
상태·I/O 소유권과 공통 제약은 [`ARCHITECTURE.md`](ARCHITECTURE.md),
현재 실행 결과는 [`VERIFICATION.md`](VERIFICATION.md)에 있다.

## Package roots

```text
AppleLocalAI/
├── Package.swift                 # iOS 27 + macOS 27 shared SDK
├── Sources/                      # AppleLocalAI + pure AppleLocalAICore
├── Tests/
├── Backends/                     # explicit OS 27 optional runtimes
├── Compatibility/AppleLocalAISystem/
│   └── Package.swift             # isolated OS 26 system-session factory
├── Examples/                     # independent consumer projects
└── Platforms/macOS/
    ├── Package.swift             # macOS-only hosts and adapters
    ├── Sources/
    ├── Tests/
    ├── packaging/
    ├── integrations/
    └── script/
```

Root `Package.swift` is never a Mac app/server package. Mac `Package.swift` depends on
the root through `../..` and never reverses that dependency. A Mac source target keeps
its `PlatformRequirement.swift`; the deployment minimum is not the platform exclusion
mechanism.

`Compatibility/AppleLocalAISystem` declares iOS 26/macOS 26 and depends only on the
Apple SDK. A lower OS consumer adds this package directly, not the OS 27 root or
Backends graph. The root, standalone LEAP and Mac package minima remain 27.
`#available` is a runtime API guard; it does not override SwiftPM's dependency
deployment minimum. No compatibility dependency is injected into the default graph.
The root requires Swift 6.4/Xcode 27. The system compatibility leaf requires Swift
6.2+, without changing the root. `Examples/SystemModel` consumes only the OS 26
leaf; `Examples/SystemModel27` consumes only the OS 27 root SDK. They have distinct
projects, schemes, bundle IDs and inference opt-ins. Simulator host metadata is
recorded separately; a macOS 27 host does not redirect the OS 26 consumer to the root SDK.
Only the installed Swift 6.4 toolchain has been compiled here; Swift 6.2 build proof
remains separate from source compatibility and OS deployment.

## Platform matrix

| Capability | iOS 27 | macOS 27 | Owner |
|---|---|---|---|
| System model/session | shared SDK | shared SDK + Mac host | Foundation Models |
| Core AI | shared factory | Mac composition over shared factory | Core AI runtime |
| MLX LLM/VLM | shared factory | Mac composition over shared factory | MLX Swift runtime |
| LiteRT-LM | platform-specific native artifact | platform-specific native artifact | official LiteRT runtime + narrow adapter |
| LEAP text/audio | shared optional product | can consume shared product | LEAP actor/runtime |
| App/Console/HTTP Provider | not part of root products | Mac-only package | Mac targets |
| PCC | explicit Apple service selection | explicit Apple service selection | Foundation Models/PCC |
| external Chat Completions | not in root package | explicit Mac adapter | Apple Utilities + host credential policy |

The independent system compatibility factory supports iOS 26+/macOS 26+ using the
concrete `SystemLanguageModel` initializer. System-model eligibility, settings and
asset readiness still apply on every OS. It does not make an unsupported device
eligible or backport custom local-model execution into Foundation Models 26.

Shared SDK availability does not imply equal device capability. Model asset admission,
native availability, device eligibility, locale, entitlement, and first inference are
separate checks.

## Compilation boundary

The Mac manifest declares macOS 27. Each Mac source target additionally rejects iOS,
Simulator, and non-Apple compilation with its local `PlatformRequirement.swift`. The
platform guard script checks those negative/positive cases; it does not build native
products.

Manifest conditions describe package dependency selection, not the build host's ability
to run a different destination. The root package must not import Mac UI, NIO, Keychain,
or Mac-only server code.

## Runtime boundary

```text
host input + explicit choice
  → shared admission / selected LanguageModel
  → native LanguageModelSession
  → backend executor/runtime
  → native response, usage, error
  → host UI or Mac Wire projection
```

The session owns transcript, usage, tools, and structured output. Backend factories own
model construction and local asset checks. Mac hosts own settings, permissions, HTTP
transport, and presentation. No host copies a native adapter and no backend is silently
replaced by another one.

## Backend-specific constraints

- Core AI requires the official model resource/bundle and explicit unload on failed or
  cancelled construction.
- MLX requires a local directory with the required configuration/tokenizer/weights; the
  directory identity is canonicalized before active-session reuse.
- LiteRT uses the official native runtime through the shared compatibility boundary.
  Transcript/schema/tool preflight and output budgets apply before engine admission;
  unmeasured token usage or ambiguous terminal causes are not fabricated.
- LEAP preparation is explicit. Artifact size/hash validation, staging, atomic promotion,
  and runner lifecycle belong to the LEAP product; microphone, playback, and permissions
  belong to the host.
- PCC and remote models are not local models. Consent, quota, endpoint, credentials,
  and network policy remain explicit.

## Platform non-goals

This repository does not add a Mac daemon to the shared SDK, a Python model server,
automatic cloud/CPU fallback, model conversion, or a plugin registry. A Simulator compile
or a cached Metal kernel is not native device inference evidence. Current qualification
status is recorded only in [`VERIFICATION.md`](VERIFICATION.md).
