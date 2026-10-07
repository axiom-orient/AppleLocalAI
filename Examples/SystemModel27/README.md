# Apple System Model 27 sample

iOS 27+·Xcode 27·Swift 6.4 toolchain용 독립 SwiftUI consumer입니다.
루트 `AppleLocalAI` product만 참조하고, 실제 `AppleLocalAISession`·`AppleLocalAIProfile`에
`SystemLanguageModel.default`를 연결합니다. 모델·대화 기록은 Apple native session이 소유합니다.
선택 backend는 의존성에 포함하지 않습니다.

`AppleLocalAISystem27Sample.xcodeproj`의 `AppleLocalAISystem27Sample` scheme을 엽니다.
Apple Intelligence 지원 기기·설정 활성화·모델 준비가 필요합니다.
질문·실행·중지와 실제 native availability를 표시합니다. UI는 작업 Task 하나를 소유하며
SDK phase가 idle로 정착하기 전 새 작업이나 session 교체를 허용하지 않습니다.
이 샘플은 `.preserveTranscript`를 명시하여 중지한 turn의 native 기록을 보존합니다.
iOS 27 Simulator에서 `.revertTranscript`의 취소·재사용 Range 크래시가 관측됐기 때문입니다.
SDK의 기본 정책은 그대로 `.revertTranscript`이며 자동 정책 전환은 없습니다.

Run argument `--verify-system-model27`은 같은 SDK session에서 실제 응답·stream·실행 중 취소·
재사용·구조화 응답·profile 변경과 명시적 reset을 검증합니다.
stream의 실제 snapshot 수·마지막 내용과 native transcript 일치·기존 history prefix 보존을
확인합니다. 취소는 SDK가 running일 때 요청하고 실제 취소 오류와 idle 복귀를 확인합니다.
history는 검증 시 읽기만 하며 별도 대화 저장소로 관리하지 않습니다.

Documents의 `system-model27-verification.json`에 runID·OS·availability·완료 단계를
원자적으로 저장합니다. 실행 전과 단계 완료 시 `RUNNING`, 모든 실제 기준 완료 시
`INFERENCE_PASS`, native unavailable 시 `UNAVAILABLE`, 오류는 `FAIL`입니다.
사용 불가나 단순 빌드로 추론 성공을 인증하지 않습니다.

Hosted Swift Testing의 실제 검증은 `APPLE_LOCAL_AI_SYSTEM27_INFERENCE_TESTS=1`
build setting으로 활성화합니다. tests는 앱의 동일 visible verification 경로를 호출합니다.
활성화된 실제 추론 테스트에서 unavailable·safety·출력 제한·취소 미관측 오류는 성공이나 skip으로 바꾸지 않습니다.
현재 실행 증거와 정책별 제한은 [검증 기록](../../docs/VERIFICATION.md)에 있습니다.

저장소 root에서 `scripts/verify-system-model.py --simulator <27-UDID>`에
명시한 `--developer-dir`과 새 외부 `--output` 디렉터리를 전달하면 이 프로젝트만 검증합니다.

프로젝트 설정 변경 시 이 디렉터리에서 `xcodegen generate`를 실행합니다.
