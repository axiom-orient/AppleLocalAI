# Native development

환경 기준은 Xcode 27, Swift 6.4, macOS/iOS 27이다. Mac package의 App·Console·Provider는
macOS 대상이며, shared SDK의 책임과 경계는 [`../../../docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md)에
있다.

## Safe checks

```sh
../../scripts/check-architecture.sh
../../scripts/check-platforms.sh
python3 ../../scripts/check-portable.py --output /tmp/applelocalai-portable-fresh
xcrun swift-format lint --recursive --strict Sources Tests
```

범위별 결과는 root [`VERIFICATION`](../../../docs/VERIFICATION.md)에 기록한다.

## Model-independent native checks

모델을 자동 다운로드하지 않고, 사용자가 준비한 명시적 asset과 prompt를 사용한다.

```sh
APPLELOCALAI_MODEL_PROMPT='What is 17 + 25? Answer with only the number.' \
APPLELOCALAI_MODEL_EXPECTED=42 \
./script/verify_model.sh system

APPLELOCALAI_MODEL_PROMPT='What is 17 + 25? Answer with only the number.' \
APPLELOCALAI_MODEL_EXPECTED=42 \
./script/verify_model.sh mlx /absolute/model-directory

APPLELOCALAI_BACKEND=cpu \
APPLELOCALAI_MODEL_PROMPT='What is 17 + 25? Answer with only the number.' \
APPLELOCALAI_MODEL_EXPECTED=42 \
./script/verify_model.sh litert /absolute/model.litertlm
```

이 명령의 PASS는 지정 asset의 해당 workflow만 증명한다. model name, format label,
`/health`, `/v1/models`, configuration check는 inference/quality 증거가 아니다.

## Provider checks

```sh
python3 script/verify-provider.py
swift run AppleLocalAIProvider \
  --config integrations/Provider/provider.example.json --check-config
```

Mac package의 최소 동작 gate는 다음 한 명령을 사용한다. Mac behavior test와 세
제품의 release build, provider/console 실행, package format과 App bundle 설정을
확인한다. root/iOS/portable 경계 검사는 root 문서의 명령을 별도로 실행한다.

```sh
./script/check.sh
```

형식 거절과 configuration parse를 inference 성공으로 기록하지 않는다. Provider의
외부 API 의미와 supported schema는 [`PROVIDER_CONTRACT.md`](PROVIDER_CONTRACT.md)가
소유한다.

## Workflow

실제 업무 workflow는 명시적 runtime·model·image·expected value를 사용한다.

```sh
./script/verify_workflow.sh meeting system
./script/verify_workflow.sh meeting mlx /absolute/model-directory
xcrun swift script/make_test_image.swift /absolute/receipt.png \
  Tests/Fixtures/expense-receipt.txt
```

## Native qualification rule

실행 결과만 root verification ledger에 추가한다. cancellation, disconnect, resource
release, device, signing, PCC 결과를 source/fixture/다른 checkout의 로그로 대체하지
않는다. 미실행은 `NOT_RUN`, 외부 소비자·persisted migration처럼 확인할 수 없는 것은
`[UNKNOWN]`으로 기록한다.
