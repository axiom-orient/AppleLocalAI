# macOS 제품 계약

macOS 27 앱·Console·Provider는 shared SDK의 Apple `LanguageModelSession`을 사용합니다.
모듈·상태·I/O 소유권은 [ARCHITECTURE](../../../docs/ARCHITECTURE.md),
HTTP 의미는 [PROVIDER_CONTRACT](PROVIDER_CONTRACT.md), 실행 결과는
[VERIFICATION](../../../docs/VERIFICATION.md)이 소유합니다.

## 실행

- App은 유효한 질문·settings·준비된 모델을 받아 partial·completed·cancelled·failed를 표시합니다.
- Console은 명시적인 command·path·endpoint를 진단하고 결과와 exit status를 반환합니다.
- Provider는 인증된 HTTP/JSON을 받아 JSON/SSE로 응답하고 client-owned 도구 호출을 handoff합니다.
- System, Core AI, MLX, LiteRT, 명시적으로 허용한 PCC·remote 모델은 선택한 native factory로 연결합니다.

모델이 준비되지 않았거나 요청 capability가 없으면 실패를 표시합니다. 자동 fallback은 없습니다.
App이 실행하는 도구와 Provider가 외부 client에 전달하는 도구의 권한은 구분합니다.

## 상태와 출력

대화 기록·도구·usage는 Apple 세션이 소유합니다. App은 기록의 읽기 전용 projection과
현재 턴만 표시하며 별도 transcript를 저장하지 않습니다. 모든 늦은 결과는 실행·세션
identity를 확인합니다. 취소·설정 변경·새 대화는 기존 native 작업 정착 후 처리합니다.

Provider는 process당 native generation 하나를 허용합니다. 지원하지 않는 schema·sampling·
입력은 모델 실행 전에 거절합니다. 빈 출력, 잘못된 도구 ID·arguments, output budget 초과는
성공이 아닙니다. 미측정 usage와 구분되지 않는 terminal cause를 추정하지 않습니다.
형식·한도는 [Wire](../Sources/AppleLocalAIWire)와 소유 코드에 정의합니다.

## 자산과 권한

Mac host는 사용자가 선택한 모델 폴더·파일을 사용하며 자동 다운로드·변환·재배포하지 않습니다.
Core AI는 embedded tokenizer와 bundle 내부 asset만 허용합니다. MLX는 config·tokenizer·weights,
LiteRT는 실제 container와 LLM metadata가 필요합니다. 파일 형식이나 모델명만으로 추론과
capability를 보장하지 않습니다. 모델 자산은 Git에서 제외합니다.

자격 증명은 App Keychain 또는 Provider의 지정 환경 변수에 저장하며 설정 JSON·로그에 넣지 않습니다.
PCC·remote는 네트워크 경로입니다. 제3자 고지와 license는 보존합니다.
