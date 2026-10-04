# Native qualification plan

이 문서는 native qualification에 필요한 조건과 중단 기준만 소유한다. 자동으로
실행되지 않으며, 결과는 [`../../../docs/VERIFICATION.md`](../../../docs/VERIFICATION.md)에
기록한다. 이미 실행된 결과나 구현 상태를 복제하지 않는다.

## Gate 0 — static and isolated baseline

- root/Mac manifest parse
- architecture/platform boundary guards
- Swift format/parse
- portable Core/Host/Wire/LiteRT/asset suites
- isolated Mac Host/Wire/LiteRT target build

전체 SwiftPM graph가 MLX/Metal을 포함할 수 있으므로 isolated 검사와 full native
build를 같은 명령으로 취급하지 않는다.

## Gate 1 — source-identity-matched Mac build/test

Xcode 27과 Swift 6.4에서 root와 Mac package의 resolve/build/test를 실행한다. 다음을
분리해 기록한다.

- root product tests와 Mac target tests
- MLX macro/Metal, Core AI, LiteRT XCFramework, LEAP binary 조합
- App/Console/Provider compile 및 test discovery

filtered test는 lightweight selector가 아니므로 constrained 장비에서 먼저 전체 graph
영향을 확인한다.

## Gate 2 — native runtime

준비된 자산으로 System, Core AI, MLX, LiteRT 경로를 각각 실행한다.

- model selection/admission과 첫 inference를 구분
- profile switch, prewarm, cancellation, re-request, cache release를 확인
- late snapshot, measured usage, empty output, terminal cause를 확인
- HTTP disconnect와 vendor cancellation settlement/RSS를 별도 기록

실행 가능한 fixture/model이 없으면 `NOT_RUN`으로 남기고 다른 프로젝트 결과를 승계하지
않는다.

성능·RSS는 이 gate의 동작 판정에 포함하지 않는다.

## Gate 3 — device and distribution

- iOS physical device에서 shared products와 Simulator Vision boundary를 확인
- Mac App/Console/Provider packaged launch와 security-scoped files/Keychain을 확인
- LEAP nested framework signing, entitlement, PCC provisioning/quota/consent를 확인
- 모델 provenance, memory, cancellation, release evidence를 source identity와 함께 기록

## Stop conditions

실패를 expectation 완화, hidden fallback, fake model, inherited log로 덮지 않는다. SDK,
vendor runtime, asset, entitlement, hardware 중 어느 boundary에서 실패했는지 원래 오류와
함께 기록하고 source 계약에 맞는 최소 수정만 수행한다.
