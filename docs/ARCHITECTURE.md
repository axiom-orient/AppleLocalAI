# Architecture

이 문서는 현재 코드의 module·state·I/O 소유권과 공통 제약을 정의한다. 플랫폼 선택은
[`PLATFORM_INTEGRATION.md`](PLATFORM_INTEGRATION.md), 실행 증거는
[`VERIFICATION.md`](VERIFICATION.md)가 소유한다.

## Identity

AppleLocalAI는 Apple Foundation Models의 `LanguageModel`/`LanguageModelSession`
계약을 소비하는 composition SDK다. local backend는 native `LanguageModel` adapter이며
별도 transcript engine, tokenizer authority, model registry가 아니다.

```text
caller input
  → request/profile/admission
  → selected LanguageModel
  → LanguageModelSession
      ├─ transcript/history
      ├─ usage
      ├─ tools/structured output
      └─ stream/cancellation/error
  → host projection or Wire output
```

`AppleLocalAISession`은 선택적인 convenience facade다. 요청 배타성, profile 변경,
cancellation과 async consumer 오류를 관리하지만 native session의 transcript·usage를
복제하지 않는다.

text·typed·dynamic schema·async consumer 스트림은 private `consumeStream` 하나가
전달·취소·최종 snapshot·오류 우선순위를 관리한다. 취소나 consumer 오류 뒤에는
새 snapshot을 전달하지 않고 native stream의 종료를 기다린 뒤 admission을 해제한다.
모든 native 요청은 같은 세션의 `isResponding == false`까지 취소되지 않은 cleanup Task를
join한 뒤 idle로 정착한다. `isBusy`와 세션 변경 guard는 SDK 작업과 native 응답 상태를
함께 검사한다. 이 barrier는 native transcript rollback 크래시를 고치는 정책이 아니다.

LiteRT의 buffered/streamed output은 공통 byte budget과 실제 기록된 bytes로 terminal
성공 여부를 판단한다. byte/chunk 수를 token으로 해석하지 않는다. Engine cache는
load/use/drain 수명을 소유하고 session/history authority를 갖지 않는다.

LEAP text runtime은 collecting/completed와 fragment/optional usage를 한 lifecycle로
관리한다. Artifact store, text runtime, audio runtime은 서로 다른 effect boundary이며
Foundation Models transcript를 복제하지 않는다.

`AppleLocalAIHistoryPolicy.project`는 native replay와 host context 계산이 공유하는 순수
projection이다. reasoning 제외, optional empty trigger 제거, recent-entry와 initiating
prompt/tool round-trip 보존을 한 구현에 둔다. 실제 transcript는 수정하지 않는다.

## Shared module ownership

| Module | Package | Owns | Does not own |
|---|---|---|---|
| `AppleLocalAICore` | root | request normalization, history window, readiness, operation transitions | Apple SDK, filesystem, vendor runtime |
| `AppleLocalAI` | root | public profile/request/session facade, native profile projection, one active generation operation | second transcript, model files, HTTP transport |
| `AppleLocalAILocalModels` | Backends | Core AI·MLX·LiteRT asset admission과 native factories | host routing, transcript, UI, fallback |
| `AppleLocalAILEAP` | Backends | verified artifact lifecycle, LEAP text bridge, AVFAudio sidecar | Foundation transcript authority, microphone policy, fallback |
| `AppleLocalAISystem` | Compatibility/AppleLocalAISystem | live native availability preflight, native system-session construction, exact unavailable reason | session/history/usage/Task state, model files, provider routing |

## OS version boundary

The root SDK, Backends and Mac hosts remain OS 27 compositions. The optional OS 26
system-model package has no package dependencies and no import edge in either direction
with the default graph. It accepts Apple's concrete `SystemLanguageModel` and returns
Apple's native `LanguageModelSession` through the OS 26 initializer. It does not project
OS 27 `LanguageModel`, dynamic profiles, executor channels or capability metadata into
a lower OS contract.

Each caller owns the returned native session and its UI operation Task. Reuse happens
after the preceding operation settles and native `isResponding` is false. The compatibility
factory retains no model or readiness snapshot. Availability is checked at admission;
it can change afterward, so native generation errors still reach the caller.

`Examples/SystemModel` is the OS 26 consumer and consumes only this leaf. Unavailable admission is recorded as
`UNAVAILABLE`. Its `INFERENCE_PASS` requires actual response, streaming, cancellation,
native settlement, same-session reuse and canonical transcript checks. The default
`Examples/SystemModel27` is the separate OS 27 consumer, using only root
`AppleLocalAISession` and `SystemLanguageModel.default`. The 27 on-demand sample
continues to use `AppleLocalAISession` and its explicit LEAP adapter.
These paths do not share a mutable transcript or swap providers implicitly.
The OS 27 sample explicitly selects native `.preserveTranscript`, retaining
cancelled turns. The SDK default remains `.revertTranscript`; an observed iOS
Simulator rollback crash is not hidden by automatic policy substitution.

The OS 26 sample owns Simulator-only diagnostic metadata. It reads
the runtime version through `ProcessInfo` and the host version through Darwin's
read-only `kern.osproductversion`. A host/runtime difference is displayed and
recorded, without overriding native availability or blocking inference. Both
consumers admit through native availability and preserve actual generation errors.
Supplemental context-size metadata does not veto native system-model requests.
The SDK factory does not
acquire Simulator, UI, kernel-query or fallback responsibilities.

`scripts/check-architecture.sh` locks the OS minima and checks default/compatibility
dependency edges, forbidden runtime state and source imports. It is a static regression
guard; native compilation and inference remain separate evidence.
`scripts/verify-system-model.py` selects the consumer by exact Simulator runtime
major, records the selected Xcode/SDK/host, and uses separate build/result directories.
Only a passed, explicitly enabled native lifecycle test yields `INFERENCE_PASS`;
build success, missing tests and skips do not qualify a model.

## macOS module ownership

| Target | Owns | Does not own |
|---|---|---|
| `AppleLocalAIHost` | selection, readiness, remote credential policy, host state | socket, native engine, UI |
| `AppleLocalAIFoundationModels` | Mac settings → shared/native configuration | local engine implementation, second session |
| `AppleLocalAILiteRT` | LiteRT configuration values | LiteRT engine/executor |
| `AppleLocalAIWire` | request/response/schema contract | socket effect, model execution, tool execution |
| `AppleLocalAIProvider` | authenticated HTTP request lifetime and native handoff | client-owned tool side effects, automatic fallback |
| `AppleLocalAIMac` | UI, persisted settings, macOS Settings scene, security-scoped access, app composition | backend tokenizer/model implementation |
| `AppleLocalAIConsole` | explicit diagnostic commands | durable service, hidden model selection |

Mac App, Console, Provider는 서로 다른 프로세스이며 변경 가능한 세션 상태를 공유하지
않는다. Provider는 인증된 loopback HTTP와 client-owned tool handoff를 소유하지만
client tool은 실행하지 않는다. App의 권한, OCR task/revision 상태, Keychain,
security-scoped file은 App이 소유한다.

Model construction remains in the shared runtime products. Mac hosts only compose the
returned `LanguageModel` and their local policy.

Mac 앱의 `NativeResponseRunner`는 기존 세션을 받아 응답 실행·최종 검증·표시 형식을
소유한다. 세션·모델·UI 상태를 저장하지 않는다. `AppleIntelligenceModel`이 세션 재사용,
resource release, operation identity와 snapshot publication을 계속 소유하며, provider
capability는 하나의 조회 경로를 UI·admission·도구 구성에서 공유한다.

이 책임 경계는 변경되는 표현과 실행 세부를 해당 소유자 안에 두는
[Parnas의 모듈 분해 기준](https://prl.khoury.northeastern.edu/img/p-tr-1971.pdf)을 적용한 것이다.
Apple 세션·profile 계약은 [공식 동적 세션 문서](https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles)를,
원격 모델의 transport 경계는 고정 revision의 [Apple Utilities 구현](https://github.com/apple/foundation-models-utilities/blob/2aa12937e30d310687f40fc470ea35495816c9a4/Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift)을 따른다.

## State and lifecycle invariants

- `LanguageModelSession` is the only canonical text history and usage owner.
- The Mac conversation view derives a bounded, read-only projection from the native session
  history. `ConversationState` owns only the active/latest UI turn; a count boundary prevents
  that turn from appearing both in the transcript projection and the interactive view.
- `ProviderSettings.provider` is the only persisted manual provider choice; workload
  routing is a separate policy and is not persisted as a second selector.
- Every async UI/result publication checks a live request/session identity. Superseded
  success or failure is not published.
- Cancellation prevents later snapshots and waits for the child/native stream boundary
  before the operation returns idle. An already delivered external side effect is not
  rolled back.
- Original I/O and consumer errors are retained; no silent success or fallback is used.
- Local resource release occurs only at an idle boundary after relevant native work settles.
  LiteRT cache purge drains tracked generation/warmup leases and serializes new admission.
- A local profile identity includes its canonical resource path. Retargeting a symlink
  therefore cannot reuse an old MLX/LiteRT session or provider catalog entry.
- Capability declarations are admissions, not proof of native inference. Unsupported
  schema, tool, reasoning, sampling, or asset combinations fail before success is published.
- An optional caller-owned tool-call preflight runs in Foundation Models' native callback;
  throwing it propagates from the active response before the native tool call is dispatched.

## Backend boundaries

| Backend | Canonical construction | Important limitation |
|---|---|---|
| System/PCC | Foundation Models native model | availability, consent, quota, and device state remain external |
| Core AI | shared Core AI factory | bundle admission is not inference proof |
| MLX | shared local directory factory | config/tokenizer/weights and capability metadata are required |
| LiteRT-LM | shared adapter plus official runtime | measured usage and terminal causes cannot be invented |
| LEAP | explicit prepare → verify → load → use → unload | downloads and audio routing are host-controlled |
| Remote | Mac-only explicit Apple Utilities adapter | never presented as local or automatic fallback |

Adapters reject unsupported input rather than converting it into a weaker meaning. The
native session remains responsible for transcript, tool callbacks, structured output,
and measured usage.

LiteRT는 공식 `LiteRTLM` core runtime 위에 repository-owned Foundation Models adapter를
둔다. adapter·asset inspector는 공통 `AppleLocalAILocalModels`가 소유하며 Mac에는
engine을 복제하지 않는다. 지원하지 않는 audio/video·schema·sampling 의미를 임의로
변환하지 않는다. 파생 소스의 attribution과 Apache license는 root `NOTICE`와 `LICENSES`에
보존하며, SDK/upstream 변경 시 native API·실제 backend 지원을 다시 확인한다.

## Integration constraints

현재 public product·SDK·Mac Wire 계약을 보존한다. 별도 session/history engine,
provider registry, 자동 CPU/cloud/HTTP fallback, 추측한 persistence migration이나
compatibility alias를 추가하지 않는다. 자격 증명은 App Keychain 또는 Provider의
지정 환경 변수에만 두며 설정 JSON·로그로 내보내지 않는다. LEAP artifact size/SHA-256과
SwiftPM binary checksum, LICENSE/NOTICE는 실행 무결성·재배포 계약이다.

외부 SwiftPM 소비자, 이전 release의 지속 데이터와 운영 migration 요구는 현재
checkout에서 확인할 수 없어 `[UNKNOWN]`이다. 로컬 정리를 외부 호환성 검증이나
자동 데이터 복구의 근거로 사용하지 않는다.

## Related documents

- platform and dependency boundaries: [`PLATFORM_INTEGRATION.md`](PLATFORM_INTEGRATION.md)
- executed evidence and remaining gaps: [`VERIFICATION.md`](VERIFICATION.md)
