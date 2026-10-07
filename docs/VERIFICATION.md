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

## 알려진 Apple 시스템 모델 제한

2026-10-04 검증에서 macOS 시스템 모델과 iOS 27 `.preserveTranscript` 샘플은 실제
추론을 통과했습니다. iOS 27 기본 `.revertTranscript`는 취소 후 재사용 시 native
`Swift/Range.swift:761` 크래시가 관측됐습니다. SDK 기본 정책은 변경하지 않았습니다.

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
