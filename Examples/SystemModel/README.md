# Apple System Model 26 sample

iOS 26의 Apple 기본 온디바이스 모델을 직접 사용하는 SwiftUI 앱입니다.
독립 `Compatibility/AppleLocalAISystem`만 의존하며 OS 27 root SDK와 backend를 참조하지 않습니다.
모델 실행과 대화 기록은 Apple `LanguageModelSession`이 소유하고 UI는 작업 Task 하나를 소유합니다.
OS 27의 root SDK 경로는 별도 [SystemModel27](../SystemModel27/README.md) 프로젝트입니다.

`AppleLocalAISystemSample.xcodeproj`의 `AppleLocalAISystemSample` scheme을 엽니다.
Apple native availability가 available이면 실행을 허용합니다.
Simulator runtime·Mac host 버전은 진단 정보이며 버전 차이로 실행을 차단하지 않습니다.
중지·background는 Task를 취소하며, native 작업이 정착하기 전 다음 작업을 시작하지 않습니다.
미지원 기기·Apple Intelligence 비활성화·모델 미준비·실제 생성 오류를 구분해 보존합니다.

Run argument `--verify-system-model`은 같은 native 세션에서 admission → 응답 → transcript →
stream → 실행 중 취소와 정착 → 재사용 → native transcript의 7단계를 확인합니다.
실행 중 취소는 native `isResponding`을 확인한 뒤 150 ms에 요청합니다.
실제 snapshot·취소 오류·최종 응답과 transcript 일치·고유 entry ID를 검사합니다.
고유 runID와 host/runtime·availability·완료 단계를 Documents의
`system-model-verification.json`에 원자적으로 저장합니다.
모든 실제 단계가 완료되어야 `INFERENCE_PASS`이며 unavailable은 `UNAVAILABLE`, 오류는 `FAIL`입니다.
원문 오류는 JSON과 화면의 `오류 상세`에 남습니다. 자동 fallback은 없습니다.

실제 hosted XCTest는 `APPLE_LOCAL_AI_SYSTEM_INFERENCE_TESTS=1`로 활성화합니다.
명시한 runtime의 전용 프로젝트와 새 외부 증거 디렉터리를 선택하려면 저장소 root에서 실행합니다.

```sh
scripts/verify-system-model.py --os 26 --simulator <26-UDID> \
  --developer-dir /Applications/Xcode.app/Contents/Developer \
  --output /tmp/apple-system26-new-run
```

`--check-only`는 환경 조회만 하며 추론 성공이 아닙니다. runner는 실제 추론 테스트가
skip되거나 누락되면 성공으로 처리하지 않습니다. 빌드 결과와 실제 추론 결과는 별도입니다.
프로젝트 설정 변경 시 이 디렉터리에서 `xcodegen generate`를 실행합니다.

현재 macOS 27 + iOS 26.5 Simulator의 실제 추론은 Apple safety 모델 오류로 실패합니다.
기기 프로필·기본 native API와 수정된 샘플의 실행 결과는
[검증 기록](../../docs/VERIFICATION.md)과 [원문 증거](../../docs/verification/apple-api-boundaries-20261003.json)에 있습니다.
