# Verification

기준일: **2026-10-03**. 환경: macOS 27.0.1, Xcode 27.0, Swift 6.4.
요청한 **macOS 27 + iOS 26.5 Simulator의 Apple 기본 모델 추론은 아직 FAIL**이다.
26·27 프로젝트/패키지 분리와 SDK native settlement 보강을 추론 해결로 간주하지 않는다.
명령·source fingerprint·원문은 [Apple API 검증 JSON](verification/apple-api-boundaries-20261003.json)에 있다.

## Apple 시스템 모델

| 범위 | 결과 | 실제 확인한 내용 |
|---|---|---|
| root SDK/Core 회귀 | PASS | Main 33·Core 18 tests; cleanup 전/중 취소와 재진입 차단 포함 |
| 독립 OS 26 package | PASS | 기본 suite 3 passed / 2 skipped; admission 검사는 추론 성공이 아님 |
| macOS 27 root SDK | PASS | 기본 `.revertTranscript`; 실제 응답·stream·취소/정착·재사용·typed 생성·profile/reset 6단계 |
| iOS 27 root SDK 샘플 | PASS | 명시적 `.preserveTranscript`; hosted tests 2 passed를 2회 연속 실행, 화면 경로도 native 6단계 완료 |
| iOS 27 Simulator rollback | FAIL | `.revertTranscript` 취소/재사용에서 Swift Range 크래시; SDK wrapper와 직접 native 재현 모두 관측. native idle barrier만으로 해결되지 않음 |
| iOS 26.5 Simulator | FAIL | 최종 앱 admission accepted 후 native 생성 실패; hosted tests 3 passed / 실제 추론 1 failed, exit 65 |
| iOS 26 배포 빌드 | PASS | 앞선 generic arm64 iPhone 서명 없는 빌드; minimum OS 26.0 / SDK 27.0. 실제 기기 실행 증거가 아님 |
| source/project 경계 | PASS | YAML 및 생성 Xcode project 검사; 현재 의존성·배포 버전 오염 반례 4개 거절, Swift format·문서 링크 검사 |
| 지원 iPhone 실기기 | NOT_RUN | 연결된 iPhone 15(non-Pro)·iPhone 13은 Apple Intelligence 미지원 |

26 전용 `Examples/SystemModel`은 `Compatibility/AppleLocalAISystem`만 사용한다.
27 전용 `Examples/SystemModel27`은 root `AppleLocalAI`만 사용한다.
26의 host/runtime 차이는 표시·기록할 뿐 실행을 막지 않는다. runner는 정확한 runtime에
해당 프로젝트를 선택하고 별도 DerivedData/xcresult를 사용한다. 명시한 실제 추론 테스트의
Passed와 xcodebuild exit 0을 함께 확인해야 `INFERENCE_PASS`다. skip·빌드·admission은 이를 대신하지 않는다.

같은 최소 public Apple API 바이너리는 26.5에서 실패하고 27에서 실제 `Hello!`를 반환했다.
새 iPhone 17 Pro 프로필의 26.5에서도 availability는 available, contextSize는 4096이지만
같은 실패가 발생했다. 따라서 기존 iPhone 13 프로필만의 문제가 아니다.
OS 원문은 `com.apple.fm.language.instruct_300m.safety`의 host inference에서
`promptTemplateNotFound` → SensitiveContentAnalysisML 15 → ModelManager 1001을 기록한다.
호스트/runtime의 모델 정보 호환 문제는 `[ASSUMPTION]`이며 정확한 Apple 내부 수정 지점은 `[UNKNOWN]`이다.
Apple 직원도 SDK가 보내는 모델 정보와 host 모델 정보 불일치를 설명한다.
[Apple의 2026년 8월 답변](https://developer.apple.com/forums/thread/842733)
일반 Xcode Simulator 지원과 Foundation Models의 이 조합 추론 성공은 별개다.
[Xcode 지원표](https://developer.apple.com/xcode/system-requirements/)

27 샘플은 취소된 native turn을 보존하는 정책을 처음부터 명시한다. 자동 정책 전환이나
가짜 transcript 복원은 없다. SDK 기본 정책은 `.revertTranscript`로 유지하며, 해당 iOS
Simulator의 rollback 성공을 주장하지 않는다. 정확한 Range 크래시 내부 원인은 `[UNKNOWN]`이다.
추가한 SDK barrier는 같은 native 세션의 `isResponding == false`까지 기다리고 admission과
mutation을 보호하지만, 이 rollback 오류의 해결책은 아니다.
[Apple native busy 계약](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/isresponding)

시스템 모델 prewarm·도구 실제 callback/effect·Swift 6.2 컴파일·지원 기기 실사용은
별도 qualification이 필요하다. 전달·메타데이터·일부 진단 실행을 전체 기능 성공으로 세지 않는다.

### iOS 26.5 추가 조사

기본 guardrails를 유지한 `@Generable` 구조화 응답도 같은 15/1001 오류로 실패했다.
앱만 English/US로 실행해 실제 `Locale.current=en_US`를 확인했으나 기본 응답은 실패했다.
호스트의 ko_KR 설정은 변경하지 않았으므로 호스트 언어에 관한 가설까지 배제한 결과는 아니다.
공유 scheme·build 설정에서는 availability simulation override가 발견되지 않았다.

설치된 정식 macOS SDK 26.5/27.0을 같은 Xcode 27의 공개 `SDKROOT` 경로 설정으로
선택하는 대조는 성공했다. 실제 Mach-O의 SDK 값도 각각 26.5/27.0이고 양쪽 모두
macOS 27에서 `Hello!`를 반환했다. **macOS 대조이며 iOS 26.5 성공 증거는 아니다.**
[Apple Base SDK 설정](https://developer.apple.com/documentation/xcode/build-settings-reference)

다음 미검증 후보는 같은 iOS source/runtime에 정식 iPhoneSimulator SDK 26.5를 적용하는
대조다. 이 SDK는 로컬에 없으며 공식 Xcode 26.6 다운로드에는 Apple Developer 로그인이
필요하다. 현재 Mac 잠금과 로그인 미완료로 iOS SDK 대조는 **NOT_RUN**이다.
Xcode 26.6 driver의 공식 host 범위는 macOS 26.x이므로, 이 후보는 Xcode 27 driver를
유지한 SDK 선택 실험이며 혼합 조합 전체의 공식 지원을 주장하지 않는다.
[Apple 지원표](https://developer.apple.com/xcode/system-requirements/)
원문과 추가 실험은 기존 [검증 JSON](verification/apple-api-boundaries-20261003.json)에 연결했다.

## Apple Intelligence 없는 온디맨드 경로

앞선 iOS 27 arm64 iPhone 13 Simulator에서 실제 LEAP LFM2.5 230M의 캐시 없는
149 MB 다운로드·검증·응답·stream·취소·재사용·unload·캐시 reload 8단계와 hosted tests 2개가 통과했다.
Simulator는 `GGML_METAL_DEVICES=0` CPU 실행이며 `.preserveTranscript` 정책에 한정한다.
이 경로는 Apple 시스템 모델이 아니다. SDK settlement 변경 뒤 실제 hosted tests도
**2/2 PASS**다. 기존 검증된 캐시로 respond·stream·cancel·reuse·unload·cached reload를
재실행했고 새 다운로드는 하지 않았다. 실제 iPhone·Metal·성능·메모리는 미검증이다.
[온디맨드 기록](../Examples/iOSOnDemand/Verification/iOS27-on-demand.json),
[샘플 제한](../Examples/iOSOnDemand/README.md)

Mac 제품 UI·Provider·Console, Core AI·MLX·LiteRT 실제 자산 추론, PCC 권한·quota·consent,
Keychain·서명 배포·장기 자원 안정성은 이번 변경 뒤 **NOT_RUN**이다.
외부 소비자와 이전 영속 데이터의 호환성은 **[UNKNOWN]**이다.

## 재현

```sh
APPLELOCALAI_RUN_NATIVE_INFERENCE=1 swift test
swift test --package-path Compatibility/AppleLocalAISystem
scripts/check-architecture.sh
```

Simulator는 `scripts/verify-system-model.py --os 26` 또는 `--os 27`에 정확한
`--simulator`, 명시한 `--developer-dir`, 새 외부 `--output`을 전달한다.
`--check-only`는 환경 조회만 한다. [26 샘플](../Examples/SystemModel/README.md),
[27 샘플](../Examples/SystemModel27/README.md)에 실행 방법과 native 정책을 명시했다.
