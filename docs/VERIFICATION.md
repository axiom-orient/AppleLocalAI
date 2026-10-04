# Verification

기준일: **2026-10-04**. macOS 27.0.1, Xcode 27.0, Swift 6.4.
현재 소스와 각 검증 범위는 [현행 검증 기록](verification/commercial-20261004.json)에 있다.
**전체 상용 출시 준비는 미완료**다. iOS 26.5 시스템 모델 추론과 iOS 27 native rollback 오류가 남아 있다.

## 현재 판정

| 범위 | 결과 | 실제 확인한 내용 |
|---|---|---|
| 기본 SDK·Core | PASS | 보고서상 Main 33·Core 19 tests; 요청·취소·정착·기록 경계 회귀 |
| macOS 27 Apple 시스템 모델 | PASS | 실제 응답·stream·취소·재사용·typed 생성·profile/reset·도구 실행·handoff 8단계 |
| 독립 OS 26 factory | PASS | 실제 Mac host session 생성·응답; iOS 26 추론 증거가 아님 |
| iOS 27 시스템 모델 샘플 | PASS | 지정 iPhone 18 Pro, `.preserveTranscript`, 실제 추론 XCTest 2/2 |
| iOS 27 `.revertTranscript` | CRASH | 응답·stream·취소 정착 후 재사용에서 native Swift Range 크래시 |
| iOS 26.5 시스템 모델 | FAIL | 지정 iPhone 17 Pro Max, 실제 첫 응답이 safety 템플릿 오류 15/1001로 실패 |
| 선택형 LEAP 온디맨드 | PASS | 지정 iOS 27 Simulator의 실제 CPU 모델 8단계, XCTest 2/2; Apple Intelligence 증거와 별개 |
| 선택형 backend 회귀 | PASS | LocalModels 47·LEAP 50 reported tests; 비활성 native opt-ins는 추론 성공이 아님 |
| macOS 제품 검사 | PASS | strict format·test suites·App/Console/Provider Release 빌드·config/status·plist/entitlements |
| macOS 실행·전송·OCR | PASS | 격리 앱 startup, Console 실제 응답, 인증 loopback Provider response/stream/tools, 실제 VisionKit receipt OCR |
| 검증 도구·구조 | PASS | runner 계약 3 tests, 플랫폼 compiler guard 28개, 패키지·소스 경계 검사 |
| 지원 iPhone 실기기 | NOT_RUN | Apple Intelligence 지원 실기기 없음 |

Main/Backend/Mac 테스트의 fixture·skip·가용성은 실제 모델 추론과 구분한다.
macOS 전체 검사에서 별도 opt-in인 시스템/Core AI 추론·품질 검사는 skip되었다.
실제 시스템 모델 실행 근거는 위의 8단계 결과다. 모든 backend/model의 추론 성공을 뜻하지 않는다.
앱 startup은 전체 UI 검증이 아니며 Provider smoke는 responses API 경로에 한정한다.

## 알려진 native 제한

Simulator는 Mac의 모델 서비스를 사용한다. iOS 26.5의 metadata 조회는 성공했지만
실제 safety 요청의 `instruct_300m.safety` 템플릿 조회가 실패했다.
`promptTemplateNotFound` → ModelManager 1001 → SensitiveContentAnalysisML 15가 직접 오류 경로다.
OS 세대 간 요청·자산 호환성은 가설이며 최종 Apple 내부 원인은 **[UNKNOWN]**이다.
[Apple Simulator 설명](https://developer.apple.com/forums/thread/787445),
[Apple 모델 정보 불일치 설명](https://developer.apple.com/forums/thread/842733).

지정된 iOS 27 Simulator는 초기 `UNAVAILABLE` 이후 공개 API가 `available`로 바뀌었고,
새 실행에서 실제 추론이 통과했다. 미준비 상태를 성공으로 바꾸지 않았다.

SDK 기본 `.revertTranscript`는 유지되어 있다. 별도 scratch consumer에 이 정책을 명시한
실행에서도 취소 정착 뒤 재사용이 `Swift/Range.swift:761`로 충돌했다.
raw report는 프로세스 종료 때문에 `RUNNING`에 머물렀지만 판정은 **CRASH**다.
`.preserveTranscript` 샘플의 성공은 rollback 성공을 뜻하지 않는다.
취소한 turn을 보존할지 폐기할지는 caller의 명시적인 정책이다.

## 이번 정리와 회귀 근거

- 반복 도구 호출 사이의 response에서 이력 window가 시작해도 initiating prompt를 보존한다.
  수정 전 `limit: 3` 실패를 재현했으며 모든 limit·다음 prompt 경계·ordinary suffix를 검증했다.
- 빈 host의 HTTPS 설정을 Host와 Provider 양쪽에서 거절한다. 수정 전 실패·수정 후 통과를 확인했다.
- LEAP staging 삭제 실패는 원래 오류와 cleanup 오류를 함께 보존한다.
  실제 파일 권한 거부로 재현했으며 취소·남은 staging·두 underlying 오류를 검사했다.
- Mac 대화 설정 참조와 non-frozen transcript 표시 분기를 복구했다.
  원본 기록은 유지하고 지원하지 않는 항목은 별도 상태로 표시한다.
- VisionKit의 non-Sendable configuration은 분석 작업 안에 두고 URL·String만 actor 경계를 통과한다.
  같은 production source의 독립 실행 파일로 실제 receipt 이미지의 텍스트·합계 `33.00`을 인식했다.
- runner는 기존 결과 디렉터리를 덮어쓰지 않고 consumer 소스 SHA-256을 기록한다.

## 재현

```sh
swift test
APPLELOCALAI_RUN_NATIVE_INFERENCE=1 swift test
swift test --package-path Compatibility/AppleLocalAISystem
APPLE_LOCAL_AI_SYSTEM_INFERENCE=1 swift test --package-path Compatibility/AppleLocalAISystem
GIT_LFS_SKIP_SMUDGE=1 swift test --package-path Backends
python3 scripts/tests/test_verify_system_model.py
sh scripts/check-architecture.sh
sh scripts/check-platforms.sh
sh Platforms/macOS/script/check.sh
```

Backend의 LFS 제외 설정은 Apple XCFramework와 관계없는 Android LFS 자산 다운로드를 피한다.
실행한 CLI·원문 로그·xcresult는 위 JSON의 local artifact 경로에 보존한다.
모델 결과에 관한 과거 기록은 [2026-10-03 증거](verification/apple-api-boundaries-20261003.json)에 있다.

Simulator runner의 `--output`은 **존재하지 않는 새 외부 디렉터리**여야 한다.
`--check-only`는 환경 확인이며 추론 성공이 아니다.
현재 선택된 기존 기기는 26.5 iPhone 17 Pro Max (`B462783D-86CD-46ED-8C12-E147F20A65C1`)와
27.0 iPhone 18 Pro (`6F7E3B30-7343-4290-8F67-399ED0A20EBC`)다.
[26 샘플](../Examples/SystemModel/README.md), [27 샘플](../Examples/SystemModel27/README.md).

PCC 권한·consent·quota, 모든 Core AI/MLX/LiteRT 자산, 지원 실기기 성능·메모리,
장기 안정성, 서명·notarization 배포는 별도 검증이 필요하다. GitHub 소스 게시와 상용 출시 완료를 구분한다.
