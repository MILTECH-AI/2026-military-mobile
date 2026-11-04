# 태블릿 요약 실행 확인

개발 PC 기준 2026-11-03, 연결된 Samsung SM-T735N(Android 13/API 33, ARM64)에서 실제 Qwen3-0.6B Q4_0 요약 실행을 확인했다. [직전 RAG·ML 검사](11-rag-ml-qa-2026-11-03.md)에서 미설치였던 선택 요약 모델과 ARM64 네이티브 라이브러리를 이번에 준비·설치했다. 실제 업무 DB를 변경하지 않고 가상 문서와 메모리 DB로 앱이 사용하는 검색·요약 코드를 실행했다. UI 버튼을 손으로 눌러 확인한 결과와는 구분한다.

## 최종 결과

| 검사 | 결과 |
| --- | --- |
| 실제 요약 생성 | `extractive_summary`, 원문 인용 1개 반환, 생성 종료 확인 |
| 반환 문장 | 오일 필터를 분리하는 가상 절차는 가상 부품 표식을 확인하고 시험 기록을 작성하는 것입니다. |
| 인용 근거 | `OIL-EVIDENCE-PROCEDURE`, 가상 자료 3쪽과 연결 |
| 모델 로드 / 생성 / 해제 | 1,217.536 / 15,176.086 / 16.365 ms |
| 모델 해제 확인 | worker `loaded=false` |
| 부정확한 인용 | 원문에 없는 문장은 거부하고 `retrieval_only` |
| 교환주기 질문 | LLM 호출 없이 등록 규칙·원문 경로 유지 |
| 메모리 부족 조건 | 원문 검색으로 대체, 같은 세션의 LLM 재로드 차단 |
| 자동 단계 | `basic` 유지, 자동 상향 없음 |
| 오프라인·설정 복원 | 통신 차단 실행 통과, 기존 무선 설정과 일치 확인 |
| 요약 자동 테스트 | 기존 6개 통과 |
| 수정 Dart 진단 분석 | 문제 없음 |

생성 시간은 디버그 단일 사례의 관측값이며 모든 질문의 속도를 보장하지 않는다. 메모리 검사는 OS `RUNNING_CRITICAL` 신호와 debug 전용 저메모리 스냅샷을 사용했으며 실제 RAM을 고갈시킨 kernel OOM 시험은 아니다. 최초 진단은 메모리가 충분한 OS 경고에서도 강제 실패를 기대하여 실패했다. 현재 메모리 정책에 맞게 저메모리 조건을 명시한 후 다시 실행해 통과했다. 앱의 정상 메모리 정책은 변경하지 않았다.

## 구성과 재현

기존 `tools/provision_llm.ps1`에 고정된 공개 파일을 사용했다.

- llama.cpp revision `0ec4027a2a0183de87c007069adddc06e665f7de`, 소스 ZIP SHA-256 `96fc2e7f64478cf73b4eccb5e6e716f44579829b04c41e7aa267cec4fc2a4c54`.
- Qwen 모델 revision `13ac06624948e4d8589cb4b6f90100837342fcb8`, 파일 `Qwen3-0.6B-Q4_0.gguf`, 428,970,080 bytes, SHA-256 `da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4`.
- CMake 3.22.1, NDK 28.2.13676358, API 28, ARM64, Release, 정적 C++ 런타임으로 기존 `android/app/src/main/cpp`를 빌드했다. `libmaintenance_llama.so`를 `android/app/src/main/jniLibs/arm64-v8a/`에 배치하고 debug APK를 다시 빌드했다.
- 모델은 앱 `files/optional-models/qwen3-0.6b-q4_0.gguf`에 설치됐고, 원본 공개 가중치는 `models/local/qwen3-0.6b/model.gguf`에 보관한다. 소스·가중치·바이너리는 Git 제외 경로다.
- 요약 문서 fixture는 `tools/prepare_rag_qa_fixture.py --output private/qa-summary`로 만들고 기존 번들 도구로 변환했다. 절차 문장을 앞에 배치하여 두 문장 후보 제한 안에서 의미 있는 절차 추출을 확인했다. 직전 RAG 검사 입력 `private/qa-rag`와 결과는 보존했다.

[이전 보고서의 반입 절차](11-rag-ml-qa-2026-11-03.md)를 따라 요약용 `.mrag`를 `cache/maintenance-import-probe.mrag`, Qwen 파일을 `cache/maintenance-import-llm.gguf`에 준비한 뒤 실행한다.

```sh
python tools/run_rag_device_qa.py --adb /path/to/adb --serial DEVICE_ID --entry optionalModelDeviceProbe --output output/summary-device-qa
```

최종 실행 근거는 로컬 `output/qa-2026-11-03/rag-ml/device-summary-final/`의 `device-result.json`, `instrumentation.log`, 무선 설정 전후 파일과 라우트 기록이다. 실행 UUID를 결과와 대조했으며 최초 실패 결과는 `device-summary/`에 보존했다. 새 APK SHA-256은 `18fdaeab4e5d5beddd578677335bc76b4fe1ea50185affc28cc9153808beaeea`이다. 기존 132개 전체 회귀 결과는 이전 APK의 기록이고 이번에는 관련 요약 테스트 6개와 수정 진단의 정적 분석을 수행했다.

현재 태블릿에 선택 요약 기능이 설치되어 있다. 일반 앱에서는 차종에 맞는 확인된 원문 근거가 2개 이상 있어야 정비지원 화면의 ‘근거 2개로 짧은 요약 시험’을 실행할 수 있다. 이번 가상 문서를 업무 DB에 자동 등록하지 않았다. 실제 자료용 분류 패키지·공개 Vision 모델의 실행 여부는 이번 요약 검사 범위에 포함하지 않는다.
