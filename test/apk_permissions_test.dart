import 'package:flutter_test/flutter_test.dart';

import '../tools/verify_apk.dart';

const cameraOnly = '''
package: com.superkid.military.military_maintenance
uses-permission: name='android.permission.CAMERA'
''';
const backupDisabled = 'A: android:allowBackup(0x01010280)=(type 0x12)0x0';

void main() {
  test('최종 APK는 촬영 권한을 유지하고 네트워크·녹음·저장소 권한과 자동 백업을 금지한다', () async {
    final result = await inspectApk(
      'build/app/outputs/apk/debug/app-debug.apk',
    );
    expect(result['status'], 'passed');
    expect(result['allowBackup'], isFalse);
  });

  test('APK 검사기는 불필요한 권한·자동 백업·촬영 권한 누락을 거부한다', () {
    for (final permission in [
      'INTERNET',
      'ACCESS_NETWORK_STATE',
      'RECORD_AUDIO',
      'READ_EXTERNAL_STORAGE',
      'WRITE_EXTERNAL_STORAGE',
      'MANAGE_EXTERNAL_STORAGE',
    ]) {
      expect(
        () => validateApkDump(
          "$cameraOnly\nuses-permission: name='android.permission.$permission'",
          backupDisabled,
        ),
        throwsStateError,
        reason: permission,
      );
    }
    expect(validateApkDump(cameraOnly, backupDisabled)['status'], 'passed');
    expect(() => validateApkDump(cameraOnly, ''), throwsStateError);
    expect(
      () => validateApkDump(
        cameraOnly,
        'A: android:allowBackup(0x01010280)=(type 0x12)0xffffffff',
      ),
      throwsStateError,
    );
    expect(
      () => validateApkDump('package: $appPackage', backupDisabled),
      throwsStateError,
    );
  });
}
