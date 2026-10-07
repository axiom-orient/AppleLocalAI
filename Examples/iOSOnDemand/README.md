# iOS On-demand sample

iOS 27+에서 LEAP로 LFM2.5 230M Q4_0을 내려받아 로컬 추론을 실행하는 SwiftUI 앱입니다.
Apple Foundation Models의 `LanguageModel`·`LanguageModelSession`과
`AppleLocalAISession`을 사용합니다. Apple Intelligence 모델과 별도 경로입니다.

## 실행

Xcode 27에서 `AppleLocalAIOnDemandSample.xcodeproj`와 같은 이름의 scheme을 엽니다.
첫 실행에는 약 149 MB 다운로드가 필요합니다. **실행**은 다운로드·검증·로드·스트리밍을
진행하고, **중지**는 native 작업이 정착할 때까지 기다립니다. **메모리 해제**와 앱의
background 전환은 세션이 idle이 된 뒤 모델을 unload합니다. 다운로드한 파일은 보관합니다.

로컬 패키지는 root `AppleLocalAI`와
`Backends/Sources/AppleLocalAILEAP`입니다. 다른 선택 backend는 resolve하지 않습니다.
LEAP 0.11의 `LeapSDK`와 `inference_engine`은 독립 프레임워크이며 SwiftPM/Xcode가
앱에 포함하고 서명합니다. 실기기 실행에는 자신의 개발 팀을 선택합니다.
프로젝트 설정의 정본은 `project.yml`이며 변경 후 `xcodegen generate`를 실행합니다.

Simulator scheme은 `GGML_METAL_DEVICES=0`으로 CPU를 사용합니다. 기기 SDK는
`GGML_METAL_DEVICES=1`을 전달합니다. 이 설정은 앱 실행 환경이며 패키지가 전역 환경을
변경하지 않습니다. 새 0.11의 Simulator Metal 경로와 실제 iPhone 성능은 미검증입니다.

## 세션과 검증

`OnDemandModel`이 UI 작업·runtime·session을 소유합니다. 실행 UUID로 늦은 callback을
차단하고 cancel→settle→unload 순서를 지킵니다. 대화 기록은 Apple 세션이 소유합니다.
SDK의 고정 `.preserveTranscript` 정책을 사용합니다. 최신 실행 결과는
[VERIFICATION](../../docs/VERIFICATION.md)에 있습니다.

Run arguments의 `--verify-on-demand`는 실제 응답·stream·취소·재사용·unload·reload를
확인하고 앱 Documents의 `on-demand-verification.json`에 결과를 기록합니다.
hosted XCTest는 `APPLE_LOCAL_AI_ON_DEMAND_TESTS=1`일 때 실제 모델 검증을 실행합니다.
비활성 테스트나 앱 실행만으로 추론 PASS를 기록하지 않습니다.

모델은 고정 revision·크기·SHA-256을 검사하며
[LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF/blob/cdf97bd8205908758f44aec508d68ac1aef98f5c/LICENSE)을 따릅니다.
[LEAP upstream](https://github.com/Liquid4All/leap-sdk)은 deprecated로 표시된 SDK입니다.
