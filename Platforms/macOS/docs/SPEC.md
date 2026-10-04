# 제품 계약

구현 현황이 아니라 보존할 규범이다. 실행 증거는 [root VERIFICATION](../../../docs/VERIFICATION.md), 외부 전송의 세부 의미는 [PROVIDER_CONTRACT](PROVIDER_CONTRACT.md), 남은 qualification 조건은 [PLAN](PLAN.md)이 소유한다.

## 필수와 선택 기능

필수 코어는 모델 선택·admission, Apple `LanguageModel` factory, native `LanguageModelSession`, 명시적 실패, App/Console/Provider의 분리다. System model은 availability·locale·요청 capability를 확인한다. 공개 라이브러리 계약과 macOS 실행 제품의 책임을 구분한다.

선택 backend는 Core AI resources, 사용자 소유 MLX LLM/VLM directory, LiteRT container, 명시적으로 허용한 PCC, 승인된 Chat Completions endpoint다. Apple/vendor의 공식 runtime을 사용하며 LiteRT의 repository-owned compatibility adapter만 좁게 허용한다. 새 backend를 추가할 때는 [공통 backend 경계](../../../docs/PLATFORM_INTEGRATION.md#backend-specific-constraints)와 [Mac ownership](../../../docs/ARCHITECTURE.md#macos-module-ownership)을 함께 만족해야 한다.

선택 capability는 typed/dynamic guided output, native tool calling, reasoning, 이미지 입력, OCR·barcode·image metadata·Spotlight 도구, bounded history view다. backend가 존재한다고 이 기능들이 자동 지원되는 것은 아니다. 수동 외부 server bypass는 허용된 외부 연동 방식이지 App의 필수 의존성이나 내장 실행 기능이 아니다.

## 입력·출력·전제조건

| 표면 | 입력과 전제 | 관찰 가능한 출력·거절 |
|---|---|---|
| App | 텍스트 또는 이미지에 대한 유효한 기본 질문, settings, canonical history, 준비된 모델 | text/structured 표시, partial·completed·cancelled·failed 구분; 빈 최종 답을 성공으로 확정하지 않음 |
| Console | 지원 command·명시적 path/endpoint/환경 변수 | stdout/stderr와 exit status; 진단만으로 모델 적합성을 보장하지 않음 |
| Provider | 인증된 HTTP/JSON, 지원 API subset, 완결된 입력 tool history, model profile | JSON/SSE 또는 명시적 오류; client tool은 call id/name/arguments로 handoff |
| Library | 공개 initializer와 value 계약, 지원 자산, 실제 Apple/vendor API | native model 또는 명시적 오류; 독립 session authority를 생성하지 않음 |

OS와 도구 체계는 `Package.swift`를 따른다. 모델·entitlement·locale·자산 읽기·endpoint·자격 증명이 전제조건이다. secret은 App Keychain 또는 Provider의 지정 환경 변수에 두고 설정 JSON과 로그에 저장하지 않는다.

## 상태·history·권한 불변식

```text
Input/Event → validation/selection → state transition
→ native effect → result/event → guarded state transition → output/failure
```

새 요청은 실패한 요청의 결과로 바뀌지 않는다. 늦게 도착한 결과는 operation/session identity를 확인한 뒤에만 표시를 변경한다. 설정 변경·새 대화·재시도가 실행 중 effect와 경쟁하면 취소·정착 후 적용한다.

canonical history와 UI projection은 다른 소유물이다. native history를 잘라 저장하지 않는다. bounded history는 기본 크기를 넘더라도 tool call/output이 속한 시작 prompt부터 보존한다. reasoning view 변환은 provider-specific trace를 다른 모델로 재생하지 않기 위한 것이며 canonical 기록 삭제가 아니다.

Mac App은 `LanguageModelSession`의 native history에서 설정된 recent-entry 범위만 읽어
이전 사용자 입력, 응답, 도구 호출·결과를 표시한다. 현재 진행·완료·오류 상태의 턴은
`ConversationState`에서 표시하고, 경계 이전 transcript 항목과 중복하지 않는다. 이전
기록을 화면에서 생략해도 canonical session transcript는 유지한다.
새 요청은 최신 턴으로 이동한다. 응답 중 사용자가 위 기록으로 스크롤하면 자동 추적을
멈추고, 다시 최신 위치에 도달하면 이어서 추적한다.

Provider는 process당 native generation 하나를 허용한다. queue·dedup·persistent response store·client effect rollback을 제공하지 않는다. 재요청은 별도 실행이다. App의 도구 callback과 Provider의 client-owned handoff는 같은 권한이 아니다.

## 관찰 가능한 수용 기준

1. 동일 설정·입력의 selection decision을 해당 model factory에 전달한다. 요청에 필요한 capability가 없으면 실행하거나 자동 fallback하지 않는다.
2. unsupported JSON Schema 제약은 active request의 native model load/generation 전에 거절한다. 지원 subset만 Apple `DynamicGenerationSchema`/`GenerationSchema`로 변환한다. prompt-only JSON을 guided generation 성공으로 처리하지 않는다.
3. history window 경계에서 tool 원인·ID·결과가 유실되지 않는다. tool result의 callback authority와 external effect 위치가 바뀌지 않는다.
4. JSON과 SSE가 같은 최종 output validation을 사용한다. 빈 결과, 잘못된/중복 tool ID, 비객체 arguments, 예산 초과를 성공으로 반환하지 않는다. required tool 요청에서 호출이 없으면 실패다.
5. 미측정 usage는 외부 API에서 생략하거나 명시적으로 실패한다. 문자 수를 token 측정치로 위장하지 않는다. 정확한 terminal cause가 필요한 외부 API에서 backend가 output-cap 종료와 natural stop을 구분하지 못하면 해당 조합을 선행 거절한다. 형식 적합성과 업무 의미 정확성은 별개로 평가한다.
6. 취소·deadline·disconnect 후 새 성공 terminal을 만들지 않는다. 이미 관찰된 partial bytes는 rollback하지 않는다. backend 취소의 실제 종료와 자원 해제는 별도로 확인한다.
7. native generation 값은 Apple Foundation Models가 표현 가능한 범위에서만 admit한다. `temperature`는 0...1 inclusive이며, 선택된 sampling/history 값도 제품 범위 안에서만 native로 전달한다. 범위 밖 값을 clamp·default 처리하지 않고 실행 전에 거절한다.
8. App은 로컬 모델 사용을 위해 Python server를 실행하지 않는다. `--check-config`와 `/health`, `/v1/models`를 실제 inference 성공으로 해석하지 않는다.

형식과 한도 원본: [Wire](../Sources/AppleLocalAIWire), [native 요청 스키마](../Sources/AppleLocalAIProvider/NativeRequestSchemas.swift), [App 출력 스키마](../Sources/AppleLocalAIFoundationModels/FoundationModelsResponseSchema.swift). 수치 정의는 소유 코드에 있으며 이 문서에 별도 설정 정본을 만들지 않는다.

## 모델 자산·provenance

모델은 사용자 소유 자산이며 자동 다운로드/변환/재배포하지 않는다. 로컬 개발 파일은 `.runtime/models`/`.runtime/fixtures`처럼 소스와 분리한다. MLX는 config/tokenizer/weights, vision은 processor metadata까지 보존한다. LiteRT는 실제 container header와 공식 metadata를, CoreAI는 공식 resources/AOT bundle을 확인한다. 형식 일치는 load/추론/quality의 증명이 아니다. GGUF를 이름만 바꿔 다른 포맷으로 사용하지 않는다.

모델명·4bit/QAD 같은 학습/양자화 명칭으로 modality·tool/schema 지원을 추론하지 않는다. revision/hash/architecture/tokenizer/processor/license와 실제 capability를 별도로 확인한다. 일반 int4를 다른 학습 방식으로 표시하지 않는다. 오디오 metadata만으로 native audio 입출력 지원을 광고하지 않는다. 현재 model/runtime 조합의 검증 결과는 VERIFICATION만 소유한다.

자격 증명은 App Keychain 또는 지정 env에 둔다. 원본 source와 LICENSE/NOTICE를 보존한다. 테스트 이미지의 fixture·기대값은 caller가 명시하며 모델 브랜드만으로 정답을 판정하지 않는다.
