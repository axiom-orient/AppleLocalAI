# Core AI 리소스 준비

앱은 공식 `apple/coreai-models` 패키지의 `CoreAILM` 제품을 의존하며, `CoreAILanguageModels` 모듈의 `CoreAILanguageModel`을 사용한다. 세션 연결과 소유권은 [구조](../../../../docs/ARCHITECTURE.md#macos-module-ownership)에 정의한다.

## 앱에서 사용

1. Apple의 [coreai-models](https://github.com/apple/coreai-models) 절차로 대상 플랫폼의 모델 리소스 폴더를 내보낸다.
2. 모델과 tokenizer 등 필요한 파일을 폴더 단위로 유지한다.
3. 앱 설정의 `Offline Custom · Core AI` 영역에 폴더 경로를 입력한다.
4. `Core AI 모델 로드`가 완료되면 작업 프로필을 `Offline Custom · Core AI`로 선택한다.

로드 오류는 앱에 표시된다. 폴더 경로를 바꾼 뒤에는 다시 로드한다.

## AOT 컴파일

Metal Toolchain의 `coreai-build`가 설치된 Xcode 27에서 실행한다.

```bash
./integrations/CoreAI/compile-aot.sh /absolute/Model.aimodel /absolute/compiled macOS
```

인자는 모델 파일, 출력 폴더, 대상 플랫폼 순서다. 플랫폼은 `iOS` 또는 `macOS`이며 생략하면 `iOS`이므로 Mac 앱용 작업에는 `macOS`를 지정한다. 이 helper는 AOT 컴파일만 수행하며 tokenizer를 포함한 리소스 폴더 전체를 생성하지 않는다.

모델 파일 관리 기준은 [모델·자산 계약](../../docs/SPEC.md#모델-자산provenance), 실제 모델 Evaluation 명령은 [개발](../../docs/DEVELOPMENT.md)을 참조한다.
