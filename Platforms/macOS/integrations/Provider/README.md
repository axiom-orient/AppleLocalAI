# Foundation Models Provider

`AppleLocalAIProvider`는 **Foundation Models에 모델 실행을 맡기는 macOS loopback HTTP adapter**다. 자체 inference engine·agent·shell runner·session 저장 서버가 아니다.

현재 checkout에서는 architecture/platform guard, portable source subset, 그리고
exact-source NIO loopback transport isolation을 실행했다. 현재 checkout의 source
identity와 핀에 대응하는 native build, LiteRT live text client probe, MLX/Metal
inference qualification은 이번 실행에서 완료되지 않았으며, 전체
tool/cancellation/release/UI qualification도 미검증이다. 최신 근거는
[검증 상태](../../../../docs/VERIFICATION.md)를 따른다.

## Mac에서 시작

Apple Silicon, macOS 27, Xcode 27/Swift 6.4가 필요하다. 기본 예제는 local System model만 등록하고 PCC·외부 network를 허용하지 않는다.

```bash
export APPLELOCALAI_TOKEN="$(openssl rand -hex 32)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run AppleLocalAIProvider \
  --config integrations/Provider/provider.example.json --check-config
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run AppleLocalAIProvider \
  --config integrations/Provider/provider.example.json
```

`--check-config`는 구문·정책만 검사한다. 서버는 `127.0.0.1:8765`에 bind하고 인증 없는 요청과 browser `Origin`을 거절한다. live smoke는 별도 terminal에서 실행한다.

```bash
python3 script/verify-provider.py --api responses --model apple-local
python3 script/verify-provider.py --api responses --model apple-local --tools
```

검증 script는 token을 환경에서 읽고, real native non-stream/stream과 tool-result continuation을 확인한다. token·대화 원문을 commit하지 않는다.

## 모델 profile

설정은 `port`, `tokenEnvironment`, `allowPrivateCloud`, `allowExternalNetwork`, `profiles`를 받는다. unknown key는 실패한다. profile `id`가 API `model`이며 path/key/policy는 process 시작 시 고정된다.

```json
{
  "id": "mlx-coder",
  "backend": "mlx",
  "resource": "/absolute/path/to/local-mlx-model",
  "capabilities": ["guidedGeneration", "toolCalling", "reasoning"],
  "reasoning": "high",
  "historyWindow": 96,
  "instructions": "Use supplied client tools; never claim an action without its result."
}
```

MLX profile은 로컬 config/tokenizer/safetensors를 공식 MLXLanguageModel에 전달한다. VLM은 processor metadata와 vision capability가 필요하다. 자동 다운로드나 Python server는 없다.

LiteRT profile은 readable `.litertlm`과 metadata를 요구한다. SmolLM2 135M 예시는
text-only profile이며, 이번 검증에서 해당 자산의 native live qualification은
실행하지 않았다. native capability가 없는 tool calling 요청은 422로 거절되며,
capability를 설정값만으로 부여하지 않는다.

```json
{"id":"litert-local","backend":"liteRT","resource":"/absolute/path/to/model.litertlm","backendDevice":"cpu"}
```

이 HTTP Provider는 text/function 입력만 받으므로 LiteRT 이미지 입력을 제공하지 않는다. App/library의 vision backend는 별도 조건이다. guided/constrained decoding과 token usage는 metadata만으로 지원을 추정하지 않는다. Core AI는 공식 resources가 있는 환경에서만 등록한다.

PCC는 top-level `allowPrivateCloud:true`, SDK availability/locale/quota와 실제 entitlement가 모두 필요하다. external model은 explicit `https` endpoint와 named credential environment가 필요하며 automatic fallback은 없다.

## Alias와 API 범위

| Alias | 선택 정책 |
|---|---|
| `auto-local` | required capability를 만족하는 local candidate, config order 우선 |
| `fast-local` | System model만 |
| `offline-custom` | configured Core AI/MLX/LiteRT |
| `deep-reasoning` | reasoning capability candidate; 명시적으로 허용한 PCC 포함 가능 |

| Endpoint | 구현 범위 |
|---|---|
| `GET /health` | authenticated transport health |
| `GET /v1/models` | configured profiles의 id/backend와 `readiness: configured-not-probed`; capability나 runtime probe는 반환하지 않음 |
| `POST /v1/chat/completions` | text/function tools/stream/측정 가능한 usage |
| `POST /v1/responses` | stateless full history/text/function call-output/SSE |
| `POST /v1/messages` | text/tool_use/tool_result; measured usage required |
| `POST /v1/messages/count_tokens` | `501`; 추정 token 금지 |

JSON Schema는 지원 subset만 Foundation Models `GenerationSchema`로 변환하고, unsupported keyword/schema는 model 실행 전에 422로 거절한다. 외부 에이전트가 기계적으로 읽어야 하는 JSON은 prompt-only JSON이 아니라 `response_format`/Responses `text.format`의 `json_schema`를 사용한다. 이미지·오디오·문서 attachment, Responses 저장/background/websocket, custom/grammar/built-in tools, encrypted reasoning replay는 현재 제외한다. LiteRT usage가 미측정이면 Chat/Responses에서 생략하고 Messages는 사전 차단한다.

예를 들어 Responses API는 다음처럼 schema를 전달한다. 실제 모델이 schema를 만족하는지는 모델별 qualification이며, schema가 문법을 보장해도 정보 추출 품질까지 보장하지 않는다.

```json
{
  "model": "apple-local",
  "input": "회의 메모에서 확정된 업무와 예산 승인 여부를 추출하세요.",
  "text": {
    "format": {
      "type": "json_schema",
      "name": "meeting_tasks",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "tasks": {"type": "array", "items": {"type": "object"}},
          "budget_approved": {"type": "boolean"}
        },
        "required": ["tasks", "budget_approved"],
        "additionalProperties": false
      }
    }
  }
}
```

## 도구 권한

Provider가 선언한 function tool은 native callback에서 call id/name/arguments를 client에게 반환한다. provider process는 파일 변경·프로세스 실행·승인·rollback을 하지 않는다. 외부 agent가 자신의 sandbox/approval 규칙으로 실행한 뒤 다음 request의 tool result로 continuation한다.

자세한 상태 코드·history/schema/stream/usage 계약은 [PROVIDER_CONTRACT](../../docs/PROVIDER_CONTRACT.md), model provenance와 실제 output은 [root VERIFICATION](../../../../docs/VERIFICATION.md)에 있다.
