# 화면 기준 이미지

화면 비교는 글꼴과 네이티브 렌더러가 같은 환경의 기준 이미지를 사용한다. 현재 macOS 기준의 SDK는 Flutter **3.47.7**, Dart **3.13.5**다. SDK·엔진 리비전과 폰트 SHA-256은 `macos_arm64/environment.json`에 기록했다.

| 실행 환경 | 기준 위치 |
| --- | --- |
| Windows x64 | 기존 `test/goldens/*.png` |
| macOS ARM64 | `test/goldens/macos_arm64/*.png` |
| 그 밖의 네이티브 ABI | `test/goldens/<Abi.current()>/*.png`, 검토된 기준이 없으면 실패 |

`test/flutter_test_config.dart`가 각 테스트 파일의 실행 동안 `HostGoldenComparator`를 설정한다. 비교와 후보 생성에 동일한 경로 규칙을 사용한다. 기존 이미지는 보존하며 다른 환경의 기준으로 자동 대체하지 않는다.

일반 검증:

```sh
flutter pub get --enforce-lockfile
flutter test
```

실제 debug APK 검사에는 먼저 Android APK를 빌드하고 `APK_AAPT` 또는 Android SDK 경로도 준비해야 한다. APK 빌드·실기기 환경은 `docs/00-workspace-setup.md`와 `docs/08-tablet-qa-2026-11-03.md`를 따른다.

화면을 의도적으로 바꾼 경우에만 후보를 생성한다.

```sh
flutter test --update-goldens
```

후보와 기존 이미지를 나란히 검토하고 레이아웃·문구·필드·버튼·잘림을 확인한다. SDK나 폰트 변경도 함께 기록한다. 검토 후 반드시 **갱신 옵션 없이** 전체 테스트를 실행한다. 허용 오차는 0이며 누락된 기준도 실패한다. `golden_comparator_test.dart`는 실제 1픽셀 차이가 실패하고 기존 기준이 유지되는지 검사한다.

macOS 기준 29개는 최초 추가 시 기존 기준 29개와 모두 시각적으로 검토했다. macOS와 기존 기준의 픽셀 차이는 1.69~5.97%였고 글자·아이콘 경계에 집중됐다. 배치·줄바꿈·입력·버튼 위치를 확인했으며 넓은 단색 영역의 내부 색 변경도 발견되지 않았다. 이 환경 간 비교 수치는 향후 테스트의 허용 오차로 사용하지 않는다.
