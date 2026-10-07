# Platform integration

지원 기준은 **iOS/macOS 27 이상, Xcode 27, Swift 6.4**입니다.
상태·I/O 책임은 [ARCHITECTURE](ARCHITECTURE.md), 실행 결과는
[VERIFICATION](VERIFICATION.md)에 있습니다.

## 패키지 선택

| 패키지 | 용도 | 의존성 |
|---|---|---|
| root `AppleLocalAI` | Apple native 모델·profile·session | Apple SDK만 사용 |
| `Backends`의 `AppleLocalAILocalModels` | Core AI·MLX·LiteRT adapter | 해당 공식 runtime |
| `Backends/Sources/AppleLocalAILEAP` | 독립 온디맨드 모델 | LEAP binary·inference engine |
| `Platforms/macOS` | App·Console·HTTP Provider | root·선택 backend·Mac 전용 transport |

Mac host는 root SDK를 소비합니다. Root와 backend는 Mac UI·NIO·Keychain을 가져오지
않습니다. macOS의 각 target은 `PlatformRequirement.swift`로 다른 플랫폼 빌드를 거절합니다.
배포 최소 버전은 `Package.swift`에 정의합니다.

시스템 모델 샘플은 [`Examples/SystemModel27`](../Examples/SystemModel27/README.md),
온디맨드 샘플은 [`Examples/iOSOnDemand`](../Examples/iOSOnDemand/README.md)입니다.
두 샘플은 모델 선택이 명시적이며 세션 상태를 공유하지 않습니다.

## 기능 경계

| 기능 | iOS | macOS | 실행 책임 |
|---|---|---|---|
| 시스템 모델 | shared SDK | shared SDK·Mac host | Foundation Models |
| Core AI | shared factory | 같은 factory의 Mac 설정 | Core AI |
| MLX LLM/VLM | shared factory | 같은 factory의 Mac 설정 | MLX Swift |
| LiteRT-LM | 플랫폼별 공식 native artifact | 플랫폼별 공식 native artifact | LiteRT·shared adapter |
| LEAP text/audio | 독립 선택 product | 같은 product 소비 가능 | LEAP actor/runtime |
| App·Console·HTTP Provider | 해당 없음 | Mac 전용 | Mac targets |
| PCC | 명시적 선택 | 명시적 선택 | Apple service |
| 외부 Chat Completions | root에 포함하지 않음 | 명시적 Mac adapter | Apple Utilities·credential policy |

Apple native session이 transcript·usage·tools·structured output을 소유합니다.
Factory는 모델 생성과 자산 admission, host는 설정·권한·입출력·화면을 소유합니다.
모델 준비·device eligibility·asset admission·첫 추론은 별도 조건입니다.

## Backend-specific constraints

- Core AI는 embedded tokenizer와 bundle 내부의 실제 asset 경로를 요구합니다.
- MLX는 config·tokenizer·weights를 포함한 로컬 디렉터리를 사용합니다.
- LiteRT는 공식 metadata의 LLM 모델만 허용합니다. 지원하지 않는 schema·tool·sampling은
  실행 전에 거절하며 token usage와 terminal cause를 추정하지 않습니다.
- LEAP는 prepare→검증→load→use→unload 순서를 사용합니다. 다운로드는 product,
  microphone·playback·permission은 host가 관리합니다.
- PCC·remote는 네트워크 모델입니다. consent·quota·endpoint·credential은 명시적입니다.

자동 cloud/CPU fallback과 외부 model server 우회는 없습니다. Simulator 빌드나
cached kernel만으로 실기기 추론·성능을 보장하지 않습니다.
