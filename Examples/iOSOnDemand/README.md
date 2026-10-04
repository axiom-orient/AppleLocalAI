# iOS On-demand LLM sample

iOS 27+용 최소 SwiftUI 소비 앱입니다. Apple Intelligence 지원 기기가 없어도
LEAP로 LFM2.5 230M Q4_0을 처음 사용할 때 다운로드하고 기기 안에서 실행합니다.
Apple Foundation Models의 `LanguageModel`·`LanguageModelSession` 경계와
저장소의 `AppleLocalAISession`을 그대로 사용합니다. 원격 추론이나 모의 응답은 없습니다.
Apple의 [custom model provider 안내](https://developer.apple.com/videos/play/wwdc2026/339/)에
따라 `LanguageModelExecutor`를 세션에 연결합니다.

## 실행

Xcode 27에서 `AppleLocalAIOnDemandSample.xcodeproj`를 열고
`AppleLocalAIOnDemandSample` scheme과 iOS 27 Simulator 또는 기기를 선택합니다.
서명은 자신의 개발 팀을 선택합니다. 첫 실행에는 약 149 MB 다운로드가 필요합니다.
질문을 입력하고 **실행**을 누르면 다운로드·무결성 검사·로드·스트리밍을 진행합니다.
**중지**는 실행이 종료될 때까지 기다리며, **메모리 해제** 또는 앱의 background 전환은
세션이 idle인 시점에 profile을 비운 뒤 native 모델을 unload합니다. 다운로드 파일은 보관됩니다.
메모리 해제 후 다시 로드하면 새 대화를 시작합니다. 모델이 로드된 동안의 연속 실행은 같은 대화를 사용합니다.

로컬 패키지 참조는 `../../`의 `AppleLocalAI`와
`../../Backends/Sources/AppleLocalAILEAP`의 독립 `AppleLocalAILEAP` product입니다.
LEAP consumer는 다른 optional backend를 resolve하지 않습니다. 저장소 전체 위치를 유지해야 합니다.
앱의 post-build 단계는 기존 `scripts/sign-leap-embedded.sh`로 nested LEAP 라이브러리를
앱 identity에 맞춰 서명합니다. 서명 비활성 빌드에는 실행하지 않습니다.
XcodeGen 설정을 바꾼 경우 이 디렉터리에서 `xcodegen generate`로 프로젝트를 다시 생성합니다.

## 실제 검증

2026-10-03, Xcode 27·iOS 27의 arm64 iPhone 13 Simulator에서 CPU 실추론을 검증했습니다.
캐시가 없는 상태의 다운로드부터 응답·스트리밍·취소·재사용·unload·캐시 reload까지
**8단계 PASS**, 실제 모델 테스트를 활성화한 hosted XCTest **2 passed / 0 skipped**입니다.
generic iPhone arm64 서명 없는 빌드도 PASS입니다. 실제 iPhone 설치·성능·메모리는
기기가 없어 검증하지 않았습니다. [실제 결과 JSON](Verification/iOS27-on-demand.json)에
모델 SHA-256, 응답, 취소 trigger, native 로그와 XCTest 결과 경로를 보관했습니다.

scheme의 Run arguments에 `--verify-on-demand`를 추가하면 실제 응답·스트리밍·취소·재사용·
unload·캐시 reload와 재응답을 실행합니다. 화면에 응답과 상태를 표시하고,
앱 Documents의 `on-demand-verification.json`에 고유 runID·모델 revision/SHA-256·OS·각 단계 결과를
기록합니다. native 작업 전에 새 `RUNNING` 기록으로 원자적으로 교체하며,
각 완료 단계도 `RUNNING` 상태로 저장하여 중단 위치를 확인할 수 있습니다.
실패는 `FAIL`과 원인을 기록합니다. 기록 저장 실패도 화면에 표시합니다.
단순히 앱이 실행된 것으로 PASS를 만들지 않습니다.

취소 검증은 실제 snapshot을 받으면 즉시 취소합니다. Foundation Models가 custom executor의
snapshot 전달을 지연하는 경우에는 별도 MainActor 작업이 세션의 `running` 상태를 확인한 후
150 ms에 취소합니다. 취소 오류·idle 복귀·다음 실제 응답까지 확인하고 사용된 취소 trigger를
기록합니다. 출력 제한 오류는 성공으로 처리하지 않습니다.
샘플 profile은 `.preserveTranscript` 정책을 명시하여 취소 시 실제 partial 대화 기록을
모델이 로드된 동안 유지합니다. 이 정책은 샘플 세션에 적용됩니다.
iOS 27 취소 검증에서 기본 `.revertTranscript`는 native Range 예외가 관측되었으며,
`.preserveTranscript`의 취소·재사용·unload는 실제 CPU 실행으로 확인했습니다.
정확한 Foundation Models 내부 원인은 `[UNVERIFIED]`이며, 이 결과는 기본 rollback 정책의
검증 성공을 뜻하지 않습니다.

hosted XCTest의 실제 모델 검증은 Test 환경 변수
`APPLE_LOCAL_AI_ON_DEMAND_TESTS=1`로 명시적으로 활성화합니다.
기본 테스트 실행은 응답 검증 정책만 확인하고 실제 추론 테스트는 skip합니다.
명령줄에서는 `xcodebuild test -project AppleLocalAIOnDemandSample.xcodeproj
-scheme AppleLocalAIOnDemandSample -destination 'platform=iOS Simulator,id=<UDID>'
APPLE_LOCAL_AI_ON_DEMAND_TESTS=1`로 실제 검증을 켭니다.
Simulator 추론은 iOS package와 native ABI 연결 검증이며, 실제 iPhone 성능·메모리 검증과 구분합니다.

현재 LEAP binary는 iOS Simulator의 native Metal 경로에서 응답이 비정상입니다.
샘플 Run/Test scheme은 Simulator SDK에서만 `GGML_METAL_DEVICES=0`을 전달하여
실제 모델을 CPU로 실행합니다. 기기 SDK에서는 `GGML_METAL_DEVICES=1`로 native Metal을 활성화합니다.
이 검증은 Apple Intelligence 모델을 사용하지 않습니다. Xcode scheme을 거치지 않고
Simulator 앱을 직접 launch할 경우에도 동일한 CPU 환경 변수를 전달해야 합니다.

## 경계

`OnDemandModel` 하나가 UI 작업·runtime·session 참조를 소유합니다.
실행 UUID로 늦은 download callback의 UI 변경을 차단하고, background에서는
자신의 실행을 cancel→settle한 후 메모리를 해제합니다. 대화 기록은 package 세션이 소유합니다.
Sumday의 실행 identity·cancel/drain·resident release 경계를 참고하되 별도 agent 계층을 만들지 않습니다.
temperature·sampling·reasoning·tools는 이 최소 LEAP 경로에 전달하지 않습니다.

모델 artifact는 `AppleLocalAILEAPTextModel.default`의 고정 revision·크기·SHA-256으로
검증됩니다. 다운로드와 모델 로드는 각각 `prepareTextModel`·`makeTextModel`로 분리됩니다.

모델은 [LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF/blob/cdf97bd8205908758f44aec508d68ac1aef98f5c/LICENSE)
적용 대상입니다. [LEAP SDK upstream](https://github.com/Liquid4All/leap-sdk)은 deprecated로
표시되어 있습니다. 이 샘플은 저장소의 checksummed binary를 사용하며 장기 배포 시 runtime
유지보수 경로를 별도로 검토해야 합니다.
