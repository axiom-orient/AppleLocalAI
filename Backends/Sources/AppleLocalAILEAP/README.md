# Standalone LEAP package

iOS 27+ / macOS 27+에서 Apple Intelligence 지원 여부와 독립적으로 사용자 소유
로컬 모델을 실행하는 선택 Swift package입니다. 이 디렉터리를 Xcode의 local
package로 추가하고 `AppleLocalAILEAP` product를 선택합니다. 세션 convenience API가
필요하면 저장소 루트의 `AppleLocalAI` product도 추가합니다.

이 manifest는 aggregate `Backends`와 **동일한 소스**를 사용하며 체크섬으로 고정한
`LeapSDK`와 별도 `inference_engine` binary만 의존합니다. Core AI·MLX·LiteRT 다운로드나 별도 모델 서버가
필요하지 않습니다. 모델은 처음 `prepareTextModel`을 호출할 때 내려받습니다.

```swift
import AppleLocalAI
import AppleLocalAILEAP
import Foundation

@MainActor
func answer(cacheDirectory: URL, prompt: String) async throws -> String {
  let runtime = try AppleLocalAILEAPRuntime(rootURL: cacheDirectory)
  let prepared = try await runtime.prepareTextModel()
  let model = try await runtime.makeTextModel(from: prepared)
  let session = AppleLocalAISession(
    profile: try AppleLocalAIProfile(model: model, maximumResponseTokens: 128))
  let response = try await session.respond(AppleLocalAIRequest(text: prompt))
  try session.clearProfile()
  try await runtime.unload()
  return response.content
}
```

위 코드는 성공 경로의 순서입니다. 실제 앱에서는 오류·취소 후에도 작업 정착을
기다리고 unload를 호출합니다. 다운로드 파일은 unload 뒤에도 보관합니다.
샘플의 Simulator 개발 실행은 시작 환경 변수 `GGML_METAL_DEVICES=0`으로 CPU를
사용합니다. 패키지는 프로세스의 전역 환경을 변경하지 않습니다. 실제 iPhone의
실행·메모리·서명 검증과 구분합니다.

전체 소비 예제는 [iOSOnDemand](../../../Examples/iOSOnDemand/README.md)에 있습니다.
기본 모델은 고정 revision의 [LFM2.5-230M Q4_0](https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF)이며
[LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF/blob/cdf97bd8205908758f44aec508d68ac1aef98f5c/LICENSE)을 따릅니다.
LEAP SDK는 [upstream에서 deprecated](https://github.com/Liquid4All/leap-sdk)로 표시된
고정 호환 런타임입니다. 장기 지원이나 새로운 vendor 기능을 보장하지 않습니다.
