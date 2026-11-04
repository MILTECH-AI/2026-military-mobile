# 저장소 및 개발 환경 설정

확인일: 2026-11-03. 아래 값은 GitHub API와 내려받은 소스의 설정 파일을 확인한 결과다.

## 저장소와 현재 연결 상태

| 항목 | 값 |
| --- | --- |
| GitHub | https://github.com/Superkid0714/2026-military-mobile |
| HTTPS 복제 주소 | `https://github.com/Superkid0714/2026-military-mobile.git` |
| 기본 브랜치 | `main` |
| 공개 여부 | 공개 |
| 로컬 작업 폴더 | `/Users/seongjun/Documents/ChatGPT/군학연계` |
| 가져온 소스 | `main` 아카이브, 커밋 접두사 `b942da7` |
| Git 연결 | 완료. `.git` 이력과 `origin` 설정을 추가하고 `main` → `origin/main` 추적 확인. |
| GitHub 쓰기 권한 | 미확인. 공개 소스 읽기는 가능하나 인증 및 push는 확인하지 않았다. |

현재 Mac에서 `/usr/bin/git` 실행은 Xcode Command Line Tools 부재로 실패하지만 Codex 번들 Git 2.53.0으로 연결을 완료했다. 실행 경로는 `/Users/seongjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback/git`이다. 이후 QA 작업에서 임시 Flutter 3.47.7 / Dart 3.13.5를 `/private/tmp/military-qa-sdk/flutter`에 준비하고 잠금 파일을 유지한 의존성 설치와 테스트를 실행했다. Flutter는 전역 PATH에 등록하지 않았다. 이어서 `.tools/`에 JDK·Android SDK를 구성해 APK 빌드와 태블릿 설치도 완료했다. 원격 push는 실행하지 않았다. 결과는 [QA 보고서](07-qa-2026-11-03.md)와 [태블릿 검증 기록](08-tablet-qa-2026-11-03.md)을 따른다.

## 소스에서 확인한 설정

| 항목 | 설정 | 근거 |
| --- | --- | --- |
| 앱 이름 / 버전 | `military_maintenance` / `0.3.0+3` | `pubspec.yaml` |
| Dart 제약 | `^3.13.0` | `pubspec.yaml` |
| Flutter | stable 사용 안내, 정확한 버전 고정 없음 | `README.md` |
| Android applicationId / namespace | `com.superkid.military.military_maintenance` | `android/app/build.gradle.kts` |
| Android minSdk | 24 | 같은 파일 |
| compileSdk / targetSdk / NDK | Flutter SDK 제공 값 사용 | 같은 파일 |
| Java 소스·타깃 / Kotlin JVM 타깃 | 17 | 같은 파일 |
| Android Gradle Plugin | 9.1.0 | `android/settings.gradle.kts` |
| Kotlin 플러그인 선언 | 2.4.0 | 같은 파일 |
| Gradle wrapper | 9.3.1 | `android/gradle/wrapper/gradle-wrapper.properties` |
| ONNX Runtime Android | 1.23.2, 로컬 AAR 필요 | `tools/provision_onnx_android.ps1` |

Java 타깃 17은 Gradle 실행용 JDK 요구사항 검증 결과가 아니다. 설치 후 `flutter doctor -v` 및 실제 빌드로 도구 호환성을 확인해야 한다. 현재 release 빌드는 소스에서 debug 서명을 사용하며 배포용 서명 설정은 별도 작업이다.

## Git 연결 검증 결과

원격 저장소를 임시 폴더에 checkout 없이 복제하고 `.git`을 현재 작업 폴더로 옮겼다. `read-tree HEAD`로 인덱스만 구성하여 기존 소스와 문서를 보존했다.

```sh
origin https://github.com/Superkid0714/2026-military-mobile.git (fetch/push)
main -> origin/main
HEAD b942da740587b61e8da0d5a9f2fa713b4148cc44
```

확인 시 로컬 `main`과 `origin/main`은 같은 커밋이다. 작업 변경은 `README.md`, `AGENTS.md`, 이 문서뿐이며 앱 소스 변경은 없다. 원격 쓰기 인증과 push 권한은 아직 검증하지 않았다. 문서에 토큰을 저장하지 않는다.

이 환경에서는 위 번들 Git 경로로 명령을 실행한다. 일반 터미널의 시스템 Git도 사용하려면 `xcode-select --install`로 Command Line Tools를 별도로 설치한다. Codex 업데이트 후 번들 경로가 바뀌면 `which -a git`으로 다시 확인한다.

## 개발 실행 절차

1. Dart `^3.13.0`을 충족하는 Flutter stable, Android SDK 및 호환 JDK를 준비한다.
2. 프로젝트 루트에서 다음 명령으로 환경과 의존성을 확인한다.

```sh
flutter --version
flutter doctor -v
flutter pub get
```

3. Android 빌드 전 PowerShell 환경에서 `tools/provision_onnx_android.ps1`을 실행한다. macOS에서는 PowerShell 설치 후 다음과 같이 실행할 수 있다.

```sh
pwsh -File tools/provision_onnx_android.ps1
```

생성 위치는 `.tools/android-libs/onnxruntime-android-1.23.2.aar`이며 스크립트가 검사하는 SHA-256은 `82048d1f462218adae4ba76477089ab0ba76093d84f733540066db1a8ba6b827`이다. PowerShell 설치 및 이 스크립트의 macOS 실행은 아직 검증하지 않았다.

4. 정적 분석·회귀 검사 후 연결된 Android 기기에서 실행한다.

```sh
flutter analyze
flutter test
flutter devices
flutter run -d <Android기기ID>
```

`android/local.properties`의 `flutter.sdk`와 `sdk.dir`은 실제 설치 경로를 사용하며 Git에서 제외한다. 선택 LLM·Vision 가중치와 실제 자료 색인은 저장소에 포함되지 않으므로 README의 별도 준비 절차를 따른다. 실행 중 인터넷을 사용하지 않는 앱 정책과 개발 PC에서 의존성을 받는 절차를 구분한다.
