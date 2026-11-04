# 프로젝트 작업 기준

- 대상 저장소: https://github.com/Superkid0714/2026-military-mobile
- Git 원격 이름(연결 시): `origin`
- 기준 브랜치: `main`
- 프로젝트: 기동장비 데이터 기반 AI 정비관리 Flutter Android 앱.
- 프로젝트 설정과 로컬 연결 상태는 `docs/00-workspace-setup.md`를 먼저 확인한다.
- 현재 폴더는 Git 저장소이며 `main`이 `origin/main`을 추적한다. 시스템 Git 대신 `/Users/seongjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback/git`을 사용한다.
- 작업 전 기존 변경과 저장소 지침을 확인하고, 기능 수정 후 가능한 범위에서 `flutter analyze` 및 관련 `flutter test`를 실행한다. 실행하지 못한 검사는 구분해서 보고한다.
- 원본 업무 자료, 실제 식별자·사진, 파생 모델·색인, 인증정보는 공개 저장소에 추가하지 않는다. 기존 `.gitignore`와 README의 공개 범위를 따른다.
- 저장소가 과거 환경에서 통과했다고 기록한 검증 결과를 현재 환경에서 다시 검증한 결과로 표현하지 않는다.
