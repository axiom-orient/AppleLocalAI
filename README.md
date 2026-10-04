# AppleLocalAI

Apple Foundation Models의 native 세션을 사용하는 Swift SDK입니다.
Apple이 모델 실행, 대화 기록, 도구 호출과 사용량을 소유하며 SDK는 요청·설정·취소 경계를 관리합니다.

| 사용할 경로 | 환경 | 패키지 |
|---|---|---|
| 기본 Apple 시스템 모델 SDK | iOS/macOS 27+, Xcode 27, Swift 6.4 | 저장소 루트의 `AppleLocalAI` |
| Apple 시스템 모델 전용 factory | iOS/macOS 26+, Swift 6.2+ | [`Compatibility/AppleLocalAISystem`](Compatibility/AppleLocalAISystem/README.md) |
| 선택형 로컬 모델 | iOS/macOS 27+ | [`Backends`](docs/PLATFORM_INTEGRATION.md) |
| macOS 앱·Provider·Console | macOS 27+ | [`Platforms/macOS`](Platforms/macOS/README.md) |

**iOS 26.5 Simulator + macOS 27의 실제 시스템 모델 추론은 실패합니다.**
iOS 26 지원 실기기의 추론은 아직 검증하지 못했습니다.
iOS 27 샘플은 `.preserveTranscript` 정책으로 검증했으며 SDK 기본 `.revertTranscript`의
Simulator 취소·재사용에는 알려진 native 크래시가 있습니다.
현재 결과와 검증 범위는 [`VERIFICATION`](docs/VERIFICATION.md)에 있습니다.

## 설치

Xcode의 Package Dependencies에 `https://github.com/axiom-orient/AppleLocalAI`를 추가하고
`AppleLocalAI` product를 선택합니다. 기본 패키지는 OS 27을 요구하며 외부 패키지 의존성이 없습니다.
OS 26 앱은 저장소를 내려받아 `Compatibility/AppleLocalAISystem`을 local package로 추가합니다.
기본 SDK의 배포 최소 버전을 낮춰 OS 26 factory를 대신 사용하지 않습니다.

## 기본 사용

```swift
import AppleLocalAI
import FoundationModels

@MainActor
func ask(_ text: String) async throws -> String {
  let profile = try AppleLocalAIProfile(
    model: SystemLanguageModel.default,
    instructions: "Answer briefly.",
    transcriptErrorHandlingPolicy: .preserveTranscript
  )
  let session = AppleLocalAISession(profile: profile)
  return try await session.respond(AppleLocalAIRequest(text: text)).content
}
```

대화는 같은 `AppleLocalAISession`을 재사용합니다. `cancel()` 이후에는 실행 Task가 끝나고
`isBusy`가 false가 된 뒤 새 요청이나 설정 변경을 시작합니다. `reconfigure`는 대화 기록을
유지하며 `reset`은 명시적으로 새 대화를 시작합니다. 위 예제는 취소된 turn을 보존하는
정책을 선택합니다. SDK 기본 정책은 `.revertTranscript`로 유지됩니다.

Apple Intelligence 지원기기, 설정 활성화, 모델 다운로드 완료가 필요합니다.
`SystemLanguageModel.default.availability`를 확인하고 실제 생성 오류도 처리해야 합니다.
모델 준비 상태나 빌드 성공은 추론 성공을 대신하지 않습니다. 자동 모델 fallback은 없습니다.

## 샘플과 검증

- OS 26: [`Examples/SystemModel`](Examples/SystemModel/README.md)
- OS 27: [`Examples/SystemModel27`](Examples/SystemModel27/README.md)
- 선택형 온디맨드 모델: [`Examples/iOSOnDemand`](Examples/iOSOnDemand/README.md)
- 모듈·상태·I/O 경계: [`ARCHITECTURE`](docs/ARCHITECTURE.md)

```sh
swift test
swift test --package-path Compatibility/AppleLocalAISystem
scripts/check-architecture.sh
```

실제 모델 검증은 [`VERIFICATION`](docs/VERIFICATION.md)의 opt-in 명령을 사용합니다.
비활성화·skip·unavailable 결과를 추론 PASS로 표시하지 않습니다.

## 라이선스

AppleLocalAI 자체의 재사용 라이선스는 제공하지 않습니다. 제3자 코드의 고지와 조건은 [`NOTICE`](NOTICE)와 [`LICENSES/`](LICENSES/)에 있습니다.
