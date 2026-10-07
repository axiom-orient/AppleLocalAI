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
함께 검사한다. 오류·취소 후 transcript는 native `.preserveTranscript`로 보존하며,
되돌리기 경로를 선택하지 않는다.

LiteRT의 buffered/streamed output은 공통 byte budget과 실제 기록된 bytes로 terminal
성공 여부를 판단한다. byte/chunk 수를 token으로 해석하지 않는다. Engine cache는
load/use/drain 수명을 소유하고 session/history authority를 갖지 않는다.

LEAP text runtime은 collecting/completed와 fragment/optional usage를 한 lifecycle로
관리한다. Artifact store, text runtime, audio runtime은 서로 다른 effect boundary이며
Foundation Models transcript를 복제하지 않는다.
Staging cleanup이 실패하면 원래 오류와 cleanup 오류를 함께 보존한다.
일반 디렉터리는 삭제하지 않으며 symbolic link는 링크 자체만 제거한다.

`AppleLocalAIHistoryPolicy.project`는 native replay와 host context 계산이 공유하는 순수
projection이다. reasoning 제외, optional empty trigger 제거, recent-entry와 initiating
prompt/tool round-trip 보존을 한 구현에 둔다. 실제 transcript는 수정하지 않는다.
반복 tool cycle 사이의 response도 같은 turn에 속한다. Window 경계 이후의 tool entry는
다음 prompt 이전까지만 검사하므로 별개의 새 turn 때문에 이전 turn을 추가 보존하지 않는다.

## Shared module ownership

| Module | Package | Owns | Does not own |
|---|---|---|---|
| `AppleLocalAICore` | root | request normalization, history window, readiness, operation transitions | Apple SDK, filesystem, vendor runtime |
| `AppleLocalAI` | root | public profile/request/session facade, native profile projection, one active generation operation | second transcript, model files, HTTP transport |
| `AppleLocalAILocalModels` | Backends | Core AI·MLX·LiteRT asset admission과 native factories | host routing, transcript, UI, fallback |
| `AppleLocalAILEAP` | Backends | verified artifact lifecycle, LEAP text bridge, AVFAudio sidecar | Foundation transcript authority, microphone policy, fallback |

## OS boundary

모든 패키지는 iOS/macOS 27 이상을 기준으로 합니다. Root SDK는 외부 package 의존성이
없으며 선택 backend와 Mac host가 root를 소비합니다. 이전 시스템 factory와 하위 OS
샘플·SDK override 실험 경로는 제거했습니다.

`Examples/SystemModel27`은 root SDK와 `SystemLanguageModel.default`만 사용합니다.
온디맨드 샘플은 root SDK와 독립 LEAP product를 명시적으로 선택합니다.
모든 SDK consumer는 고정된 `.preserveTranscript` 정책을 사용합니다. 실패·취소 시
부분 entry가 남을 수 있으며, 명시적 reset이 새 대화를 시작하는 경계입니다.

`scripts/check-architecture.sh`는 package minimum과 source dependency 경계를 검사합니다.
`scripts/verify-system-model.py`는 하나의 system consumer만 실행합니다. 새 외부 output
디렉터리에 환경·선택 소스·실제 native 테스트 결과를 기록하며, build·skip·unavailable을
추론 성공으로 바꾸지 않습니다.

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
원격 모델의 transport 경계는 고정 revision의 [Apple Utilities 구현](https://github.com/apple/foundation-models-utilities/blob/cc3820def1fe016bc6cd49d958cd2f2a29be76a8/Sources/FoundationModelsUtilities/LanguageModels/ChatCompletionsLanguageModel.swift)을 따른다.

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

## Dependency versions (2026-10-07)

`Backends`와 macOS의 공통 의존성은 두 `Package.resolved`에서 같은 revision으로
해석된다. 기본 root SDK에는 외부 의존성이 없다.

| Dependency | Selected version | Upstream |
|---|---|---|
| LiteRT-LM | 0.18.0 | [release](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.18.0) |
| MLX Swift / LM | 0.32.3 / 3.32.3 | [MLX](https://github.com/ml-explore/mlx-swift/releases/tag/0.32.3), [LM](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3) |
| Core AI | 1.0.0 | [stable tag](https://github.com/apple/coreai-models/tree/1.0.0) |
| Swift Transformers | 1.3.4 (unchanged) | [release](https://github.com/huggingface/swift-transformers/releases/tag/1.3.4) |
| Swift NIO | 2.104.0 | [release](https://github.com/apple/swift-nio/releases/tag/2.104.0) |
| Foundation Models Utilities | 1.1.0-beta1, revision `cc3820def1fe016bc6cd49d958cd2f2a29be76a8` | [tag](https://github.com/apple/foundation-models-utilities/tree/1.1.0-beta1) |
| LEAP | 0.11.0-SNAPSHOT (prerelease) | [release](https://github.com/Liquid4All/leap-sdk/releases/tag/v0.11.0-SNAPSHOT) |

Utilities의 새 revision은 문서만 바뀌었으며, 정식 stable release는 없다.
LEAP는 upstream deprecated SDK를 명시적으로 선택하는 adapter다. 새 배포의
`LeapSDK`와 `inference_engine`을 독립 binary target으로 포함하며, 각 ZIP의 SHA-256을
두 manifest에서 동일하게 고정한다. 이전 nested-dylib 서명 스크립트는 제거했다.

LiteRT 0.18의 `ModelInfo.llm`만 대화 모델 metadata로 인정한다. Embedding model은
LLM capability로 승격하지 않는다. HTTP output cap의 terminal cause를 추정하지 않는
기존 제한은 유지한다. Core AI 1.0은 metadata가 실제 asset 이름을 선언해야 하며,
`.aimodel` 선언을 `.aimodelc`로 임의 치환하지 않는다. Embedded tokenizer와 bundle
내부 경로만 허용하는 admission 계약도 유지한다.

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
