# Provider 계약

입출력 의미·외부 consumer 수용 기준을 소유한다. 형식 원본은 `Sources/AppleLocalAIWire`, 실행 연결은 `Sources/AppleLocalAIProvider`다. 실행 증거는 [root VERIFICATION](../../../docs/VERIFICATION.md)에 기록한다. 이 계약의 모든 optional 조합이 현재 실모델에서 검증됐다는 뜻은 아니다.

## 입력과 인증

HTTP 1.1, GET/POST, literal loopback host, 단일 Bearer 또는 `x-api-key`, POST `application/json`을 요구한다. `/health`도 인증이 필요하다. Browser `Origin`, 압축 body, trailers, 중복 `Content-Length`, `Content-Length`와 `Transfer-Encoding`의 혼용, 지원하지 않는 transfer encoding, 알 수 없는 semantic field는 거절한다. Provider JSON config는 decode 전 4 MiB로 제한하며 credentials는 provider JSON에 저장하지 않는다.

세 API는 공통적으로 model/profile, 선행 instructions, 순서 있는 user/assistant/toolCall/toolResult, function tool schema/choice, sampling·출력 한도·reasoning·optional output schema를 `InferenceRequest`로 변환한다. body는 decode 전에 크기 검사하고 JSON integer/fraction의 표현 한도를 지킨다.

system/developer 메시지는 history 앞부분에서만 native instructions로 합친다. 중간 instruction을 앞으로 이동하거나 user로 강등하지 않는다. 사용자 text turn은 공백만인 입력을 허용하지 않는다. Messages의 같은 메시지 안 연속 text block은 임의의 새 turn을 만들지 않고 하나의 text run으로 합친다.

## 도구 history 불변식

```text
user exists before first tool call
call.id is nonempty and unique
call.name is nonempty
call.arguments is a JSON object
result.id matches exactly one preceding unresolved call
optional result.name matches that call
all input calls have one corresponding result
next user turn cannot bypass outstanding results
last entry is user input OR tool result
```

과거 tool이 현재 tool list에 없어도 call ID/name/arguments를 삭제하지 않는다. 다음 generation의 active tool은 현재 request definition만 사용한다. Claude `is_error:true`는 native `ToolOutput`의 전용 field가 없으므로 구조화된 result text로 보존한다. Provider는 tool을 실행하지 않고 call을 client에게 돌려준다.

텍스트/function 이외 tool, attachment, 암호화 reasoning history 재생은 현재 범위에서 거절한다. `strict`는 boolean만 받고, JSON Schema는 아래의 지원 subset만 Apple `GenerationSchema`로 변환한다. native model capability가 없는 tool/schema/reasoning 요청은 실행 전에 422로 거절한다. LiteRT는 prompt-driven tool envelope과 guided output을 한 turn에 동시에 강제할 수 없으므로, 실제 model load 전에 해당 조합을 422로 거절한다.

## JSON Schema boundary

OpenAI/Anthropic JSON Schema를 Foundation Models `GenerationSchema`의 Codable representation으로 직접 decode하지 않는다. `NativeRequestSchemas`가 backend load 전 request boundary에서 다음 subset을 `DynamicGenerationSchema`로 변환한다.

- `object`, `string`, `integer`, `number`, `boolean`, `array`, `null`
- `description`, `title`, `$schema`, `$comment`
- array `items`, `minItems`, `maxItems`
- object `properties`, `required`, `additionalProperties:false`
- nullable type array, non-null `anyOf`, 또는 `null` + 하나의 non-null `anyOf`

그 외 keyword, unconstrained `additionalProperties`, 잘못된 required/property/type, nullable root/array item은 명시적 unsupported/invalid error다. nullable property는 Foundation Models의 명시적 `null` union으로 보존하며, 단순 optional 필드로 축약하지 않는다. 변환 깊이는 root=0부터 32까지, node는 각 schema당 4,096개로 제한한다. `anyOf`의 parent와 null branch에도 같은 keyword 검사를 적용하며 `$ref`/unsupported 제약은 버리지 않고 거절한다. 내부 schema 이름은 구조적 index를 사용하고 원래 property key는 보존한다. `tool_choice:none`으로 비활성인 tool은 native schema로 준비하지 않는다.

변환은 schema authority를 새로 만들지 않으며 실제 validation/output decoding은 Apple Foundation Models가 소유한다. LiteRT profile은 검증되지 않은 constrained/guided capability를 광고하지 않는다. 특정 asset의 현재 실행 지원은 이 규범이 아니라 VERIFICATION과 capability admission의 근거를 따른다.

## 요청 옵션과 metadata

`max_tokens`/`max_completion_tokens`/`max_output_tokens`는 해당 API의 output limit으로 해석한다. `temperature`는 Apple Foundation Models 실행 계약과 동일한 0...1, `top_p`는 (0,1], `seed`는 nonnegative integer, reasoning은 none/low/medium/high만 받는다. 이 값의 허용이 모든 backend의 지원을 보증하지 않는다. LiteRT는 seed를 지원하지 않으므로 model load 전에 422로 거절한다.

`reasoning.summary`는 생략/null/none만 허용한다. `include:["reasoning.encrypted_content"]`는 존재하는 output item의 optional projection일 뿐 encrypted reasoning item을 만들지 않는다. encrypted history 입력은 조용히 제거하지 않는다.

`metadata`, user/cache key, safety identifier는 현재 client compatibility field다. `metadata`는 known field로 strict decode하지만 model instruction·cache·persistence·output에 전달하지 않는 **명시적 no-op**이다. 서버는 conversation 저장, 과금 원장, cache hit, background 작업을 제공하지 않는다. 이 no-op을 semantic forwarding으로 해석하지 않으며, 보존/전달로 바꾸려면 별도 contract 결정이 필요하다.

## 생성·종료·사용량

```text
HTTP parse/auth → wire validation → profile/catalog admission
→ official LanguageModel + request-local AppleLocalAISession
  → native LanguageModelSession
→ native snapshot OR exact ExternalToolHandoff OR failure
→ WireOutput JSON/SSE → terminal
```

한 process에는 generation 하나만 허용한다. native failure 후 다른 model로 자동 재시도하지 않는다. 신규 HTTP request는 이전 client의 partial session을 재사용하지 않는다. disconnect/deadline은 request task를 취소하지만 이미 client가 실행한 외부 effect를 rollback하지 않는다.

SSE는 native 누적 snapshot의 UTF-8 prefix에서 새 부분만 전송하며 grapheme 경계를 보존한다. snapshot 수정, 중복 terminal, output/tool budget 초과, 취소, native error 뒤에 성공 terminal을 만들지 않는다. Responses sequence number는 증가하고, Chat은 `[DONE]`, Messages는 `message_stop`을 제공한다.

입력/출력 token은 native 측정치만 사용한다. `cached_input ≤ input`, `reasoning ≤ output`, overflow 금지가 불변식이다. Chat/Responses는 미측정 usage를 생략하고, Messages는 측정 usage가 없으면 성공 응답을 만들지 않는다. LiteRT처럼 사전에 미측정임을 아는 경로는 load 전에 차단하고, 다른 경로에서 실행 후 미측정이 드러나면 명시적 실패다. LiteRT channel의 character/chunk 값을 token으로 추정하지 않는다.

LiteRT-LM 0.18.0은 output-token cap을 runtime에 전달할 수 있지만 public Swift stream에서 **cap 종료와 natural stop의 terminal cause를 구분해 노출하지 않는다**. 따라서 Provider의 Chat/Responses에서 `max_tokens`/`max_completion_tokens`/`max_output_tokens`가 지정된 LiteRT 요청은 model load 전에 unsupported로 거절한다. 정확한 `finish_reason`/Responses status를 추정해 성공시키지 않는다. App/library의 native cap 전달 계약은 이 HTTP 제한과 별개다.

## 오류와 한도

| 상태 | 의미 |
|---|---|
| 400 | JSON·type·history·tool result 오류 |
| 401 / 403 | auth·Origin·Host 차단 |
| 404 / 405 | route/model/method 없음 |
| 413 / 415 | body 크기/content type |
| 422 | unsupported API semantics·schema·model capability |
| 429 | 다른 native request 실행 중 |
| 499 | 전달 가능한 취소 |
| 501 | token count 미구현 |
| 502 | native generation/translation failure |
| 503 | 사용 가능한 model 또는 required measured usage 없음 |

text output은 `ProviderConfiguration.maximumOutputBytes`, tool call 수와 aggregate argument bytes는 각각 정해진 상수 한도 아래에서 terminal success 전에 검사한다. Wire encoder와 native executor 모두 logical payload를 확인하지만 encoded SSE peak memory/backpressure 전체를 이 문서만으로 보증하지 않는다.

## 외부 API 범위

| Endpoint | 구현 범위 |
|---|---|
| `GET /health` | authenticated transport health |
| `GET /v1/models` | configured profiles의 id/backend; `readiness: configured-not-probed`이며 runtime 적합성 아님 |
| `POST /v1/chat/completions` | text/function tools/stream/측정 가능한 usage |
| `POST /v1/responses` | stateless full history/text/function call-output/SSE |
| `POST /v1/messages` | text/tool_use/tool_result; measured usage required |
| `POST /v1/messages/count_tokens` | `501`; 추정 token 금지 |

이미지·오디오·문서 attachment, Responses 저장/previous response/background/websocket, custom/grammar/built-in tools, reasoning signature/summary는 현재 제외한다. HTTP/1.1 request마다 connection을 닫으며 keep-alive/multiplexing을 약속하지 않는다.

## 검증 범위의 분리

portable Wire 검사는 JSON/history/request shape/SSE/config/limits를 확인한다. native schema·tool callback·continuation과 실제 model quality/권한은 별도 검사한다. 실제 실행 결과는 [root VERIFICATION](../../../docs/VERIFICATION.md)에 기록한다. 실제 외부 client의 전체 업무 성공은 protocol probe와 별도 E2E다.

## 변경된 경계의 수용 조건

JSON/nonstream과 SSE/stream은 같은 최종 검사를 사용한다. text와 tool calls가 모두 비어 있거나 tool ID/name이 비어 있거나 ID가 중복되거나 arguments가 object가 아니면 성공을 반환하지 않는다. `required`/named tool 요청에서 실제 call이 없으면 `required_tool_missing` 오류다.

historyWindow는 tool의 원인/결과를 보존하는 **soft entry limit**다. 경계가 tool call/output에 걸리면 시작 prompt까지 확장하므로 설정값을 초과할 수 있다. 이 정책은 request view에만 적용되며 canonical history를 잘라 저장하지 않는다.

Messages의 `disable_parallel_tool_use`는 `tool_choice` 내부 boolean으로만 받는다. `true`는 native sampler가 반드시 직렬 생성한다고 가정하지 않고 terminal contract에서 검증한다. `auto`는 최대 한 call, required/named choice는 정확히 한 call이어야 하며 위반한 native 결과는 실행·절단·재시도 없이 실패한다. 잘못된 field type은 묵인하지 않는다.

Native schema 변환·정확한 Apple representation과 실제 tool continuation은 native 테스트 대상이다. portable Wire PASS는 `GenerationSchema` 의미 동등성 또는 실제 모델 준수의 증거가 아니다.
