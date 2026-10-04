# Deployment

Xcode 27·macOS 27과 실제 model resource 권한이 필요하다. 이 패키지의 모든 product는 macOS 전용이다. iOS 공통 라이브러리는 repository root에서 소비한다. iPhone localhost server는 없다.

`script/build_and_run.sh`가 macOS 앱 번들 생성과 resource/dylib 복사를 소유한다. 실제 서명·entitlement·권한·relaunch가 검증되기 전에는 배포 완료를 선언하지 않는다. 모델은 명시적으로 선택한 로컬 자산이며 앱이 자동으로 받거나 cloud/CPU로 fallback하지 않는다.

System 모델은 readiness/locale, PCC는 명시적 허용·availability·quota·entitlement를 확인한다. MLX/LiteRT는 자산 구조와 선택 backend의 실제 실행을 확인한다. SwiftPM 테스트 성공은 packaged UI나 iOS device 동작의 증거가 아니다.

실행 결과: [root VERIFICATION](../../../docs/VERIFICATION.md). 남은 qualification: [PLAN](PLAN.md).
