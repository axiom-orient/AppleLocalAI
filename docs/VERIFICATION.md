# Verification

기준일: **2026-10-07**. Xcode 27.0, Swift 6.4, macOS 27.
빌드·단위 테스트와 실제 모델 추론은 별도로 판정합니다.

## 이번 변경

| 범위 | 결과 | 근거 |
|---|---|---|
| 의존성 | PASS | 양쪽 lockfile의 공통 revision 일치; [현재 버전](ARCHITECTURE.md#dependency-versions-2026-10-07) |
| LEAP 0.11 CPU | PASS | iOS 27 iPhone 18 Pro Simulator, 실제 모델 lifecycle 8단계, XCTest 2/2 |
| LEAP 앱 포함·서명 | PASS | 별도 `LeapSDK.framework`·`inference_engine.framework` 포함; Simulator 앱 strict 서명 검사 |
| Backend build/test | PASS | LocalModels 48·LEAP 50 tests; Core AI 1.0·MLX·LiteRT·LEAP 실제 라이브러리 빌드 |
| macOS 제품 | PASS | format·전체 unit suite·App/Console/Provider Release build; 정리 후 관련 회귀 34개 |
| LiteRT 0.18 실추론 | PASS | SmolLM2-135M, CPU Provider 요청 1회; HTTP 200·completed·비어 있지 않은 출력 |
| 지원 iPhone 실기기 | NOT_RUN | Apple Intelligence 지원 실기기 없음 |

LEAP는 고정 revision `cdf97bd8205908758f44aec508d68ac1aef98f5c`의
LFM2.5-230M-Q4_0으로 응답·stream·취소 정착·재사용·unload·cache reload를 확인했습니다.
Simulator UUID는 `6F7E3B30-7343-4290-8F67-399ED0A20EBC`이며 기존 모델 파일을 재사용했습니다.
실기기 Metal·오디오·장기 안정성은 이번 범위에서 검증하지 않았습니다.

LiteRT는 공개 [SmolLM2-135M 모델](https://huggingface.co/litert-community/SmolLM2-135M-Instruct/tree/8111e0a65fda719f0a6855e8e1a8ec8c3f9ccb22)을 사용했습니다.
실제 production 경로의 `ModelInfo` admission·load·응답을 확인했으며, 모델 품질·GPU·
전체 lifecycle 검증을 뜻하지 않습니다. 기존 바이너리 헤더의 증분 빌드 오류는 공식
build clean 후 해소했습니다. 구조 검사·runner 회귀 3개·폐기 참조 검색도 통과했습니다.

## 세션 오류 정책 (2026-10-07)

SDK는 Apple의 [preserveTranscript](https://developer.apple.com/documentation/foundationmodels/transcripterrorhandlingpolicy/preservetranscript)
정책만 사용합니다. public profile의 정책 선택 인자와 Mac의 rollback 설정·저장 키·Picker를
제거했습니다. 실패·취소 후 부분 기록은 보존되며 명시적인 reset이 새 대화를 시작합니다.
기존 Mac JSON의 나머지 설정은 유지되고, 폐기된 policy 키는 실행에 영향을 주지 않습니다.

정책 인자 없는 실제 SDK consumer로 지정 iOS 27 Simulator에서 한 번 검증했습니다.
XCTest **2/2 PASS**, 실제 응답·8개 stream snapshot·실행 중 취소·idle 정착·같은 세션
재사용·structured 생성·profile/reset을 통과했습니다. 기존 Range 크래시는 이 실행에서
발생하지 않았습니다. 관련 SDK 회귀 21개와 Mac settings 회귀 12개도 통과했습니다.

이 변경은 native rollback을 선택하던 공개 API를 제거하는 source break입니다.
Apple 내부 rollback 결함 자체가 수정됐다는 의미는 아닙니다. 프로젝트가 그 경로를
선택하지 않도록 닫았습니다. 실기기 결과는 별도입니다.

## 경고 범위

새 system-model 실행과 root 회귀에는 자체 compiler 경고가 없습니다. AppIntents를
사용하지 않는 두 샘플은 설치된 SwiftBuild가 지원하는 `LM_SKIP_METADATA_EXTRACTION=YES`로
불필요한 앱 metadata 추출을 끕니다. 최종 두 consumer 빌드의 `warning:`는 **0개**이며,
SwiftPM dependency의 “관련 App Intents 없음” 정보 출력은 경고와 구분합니다.

선택 MLX 그래프의 resource-node·Metal 확장 진단, CPU LiteRT의 선택적 NPU 등록 진단,
Simulator의 Apple framework 중복 class 메시지는 외부 구현에서 발생합니다. 실제 CPU
검증은 통과했지만 이 메시지가 모두 제거됐다는 결과는 아닙니다. 로그를 숨기거나
vendor cache를 수정하지 않으며, 전체 외부 경고 0은 보장하지 않습니다.

과거 상세 결과는 [검증 당시 Git 이력](https://github.com/axiom-orient/AppleLocalAI/tree/1714aea0c2bfe3602878eb5dec53a64129089550/docs/verification)에 있습니다.
현재 문서에 과거 checksum·로그 경로·결과 JSON을 복제하지 않습니다.

## 필요한 검사만 실행

```sh
GIT_LFS_SKIP_SMUDGE=1 swift test --package-path Backends
sh Platforms/macOS/script/check.sh
```

실제 모델 실행은 macOS [개발 명령](../Platforms/macOS/docs/DEVELOPMENT.md),
iOS [시스템 샘플](../Examples/SystemModel27/README.md),
[온디맨드 샘플](../Examples/iOSOnDemand/README.md)을 사용합니다.
비활성 opt-in, unavailable, skip은 추론 PASS가 아닙니다. Core AI·MLX·LiteRT의 모든
자산 조합, PCC 권한·quota, 실기기 성능과 배포 notarization은 **미검증**입니다.
