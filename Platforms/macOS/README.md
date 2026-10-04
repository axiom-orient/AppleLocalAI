# AppleLocalAI macOS hosts

`Platforms/macOS`는 macOS 27 전용 SwiftPM package다. root package
[`../..`](../..)의 shared SDK를 소비하며, root SDK가 Mac host를 역의존하지 않는다.
이 디렉터리만 복사하면 shared dependency가 끊긴다.

## Products

| Product | 책임 |
|---|---|
| `AppleLocalAIMac` | SwiftUI/AppKit conversation, settings, file access |
| `AppleLocalAIConsole` | 명시적 availability/model/configuration 진단 |
| `AppleLocalAIProvider` | 인증된 local HTTP adapter |
| `AppleLocalAIHost` | 선택·상태·request policy |
| `AppleLocalAIFoundationModels` | Mac settings와 shared/native configuration 연결 |
| `AppleLocalAILiteRT` | LiteRT configuration types |
| `AppleLocalAIWire` | Provider 내부 request/response target |

App, Console, Provider는 서로 다른 composition root다. 공통 transcript/session 또는
native adapter를 복제하지 않는다. System, PCC, Core AI, MLX, LiteRT와 명시적 remote
경로를 보존하지만 LEAP를 Mac UI/Provider에 자동 노출하지 않는다.

Mac host는 SwiftUI `Settings` scene에서 설정을 표시하고 App·menu bar와 같은
`AppleIntelligenceModel`을 사용한다. 대화 화면은 Apple 세션의 canonical transcript에서
최근 기록을 읽기 전용으로 그리며, 진행 중·완료·오류 상태의 현재 턴은
`ConversationState.submittedTurn`이 표시한다. 기록 전체를 앱 상태에 복사하지 않는다.

## Safe entry points

```sh
sh ../../scripts/check-architecture.sh
sh ../../scripts/check-platforms.sh
sh script/check.sh
swift run AppleLocalAIConsole status
swift run AppleLocalAIProvider \
  --config integrations/Provider/provider.example.json --check-config
```

`--check-config`, `/health`, `/v1/models`는 configuration/transport readiness일 뿐
native inference 성공이 아니다. 전체 build/test는 SwiftPM이 filter 전에 MLX/Metal
graph를 구성할 수 있으므로 장비 여유가 있는 native qualification 환경에서만 실행한다.

## Canonical documentation

| 질문 | 문서 |
|---|---|
| module and state ownership | [`../../docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) |
| package and platform boundaries | [`../../docs/PLATFORM_INTEGRATION.md`](../../docs/PLATFORM_INTEGRATION.md) |
| normative product contract | [`docs/SPEC.md`](docs/SPEC.md) |
| HTTP/Wire contract | [`docs/PROVIDER_CONTRACT.md`](docs/PROVIDER_CONTRACT.md) |
| development commands | [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) |
| qualification gates | [`docs/PLAN.md`](docs/PLAN.md) |
| execution evidence | [`../../docs/VERIFICATION.md`](../../docs/VERIFICATION.md) |
| packaging/signing | [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) |

실행하지 않은 모델·device·signing 결과는 문서에서 PASS로 표시하지 않는다.
