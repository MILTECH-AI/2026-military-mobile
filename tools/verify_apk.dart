/// Inspect the packaged APK, including permissions contributed by plugins.
/// Run after building: `dart run tools/verify_apk.dart --apk PATH --report PATH`.
library;

import 'dart:convert';
import 'dart:io';

const appPackage = 'com.superkid.military.military_maintenance';
const allowedPermissions = {
  'android.permission.CAMERA',
  '$appPackage.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
};

Map<String, Object> validateApkDump(
  String permissionsDump,
  String manifestDump,
) {
  final package = RegExp(
    r'^package: (\S+)',
    multiLine: true,
  ).firstMatch(permissionsDump)?.group(1);
  if (package != appPackage) throw StateError('대상 앱 패키지가 다릅니다: $package');
  final permissions = RegExp(
    r"^uses-permission(?:-[^:]+)?: name='([^']+)'",
    multiLine: true,
  ).allMatches(permissionsDump).map((m) => m.group(1)!).toSet();
  final unexpected = permissions.difference(allowedPermissions);
  if (unexpected.isNotEmpty) {
    throw StateError('허용하지 않은 APK 권한: ${unexpected.join(', ')}');
  }
  if (!permissions.contains('android.permission.CAMERA')) {
    throw StateError('사진 촬영에 필요한 CAMERA 권한이 없습니다.');
  }
  if (!RegExp(r'android:allowBackup\([^)]*\)=\(type 0x12\)0x0\b')
      .hasMatch(manifestDump)) {
    throw StateError('최종 APK의 allowBackup=false를 확인하지 못했습니다.');
  }
  return {
    'status': 'passed',
    'package': appPackage,
    'permissions': permissions.toList()..sort(),
    'allowBackup': false,
  };
}

String findAapt() {
  final override = Platform.environment['APK_AAPT'];
  if (override != null && File(override).existsSync()) return override;
  final roots = <String>[
    ?Platform.environment['ANDROID_SDK_ROOT'],
    ?Platform.environment['ANDROID_HOME'],
  ];
  final properties = File('android/local.properties');
  if (properties.existsSync()) {
    final value = RegExp(
      r'^sdk\.dir=(.+)$',
      multiLine: true,
    ).firstMatch(properties.readAsStringSync())?.group(1);
    if (value != null) {
      roots.add(value.trim().replaceAll(r'\:', ':').replaceAll(r'\\', r'\'));
    }
  }
  for (final root in roots) {
    final folder = Directory('$root/build-tools');
    if (!folder.existsSync()) continue;
    final versions = folder.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final version in versions) {
      final binary = File(
        '${version.path}/aapt${Platform.isWindows ? '.exe' : ''}',
      );
      if (binary.existsSync()) return binary.path;
    }
  }
  throw StateError('Android build-tools/aapt가 필요합니다. APK_AAPT로 지정할 수 있습니다.');
}

Future<Map<String, Object>> inspectApk(String apk, {String? aapt}) async {
  if (!File(apk).existsSync()) {
    throw StateError('APK가 없습니다. 먼저 Android debug APK를 빌드하세요: $apk');
  }
  final binary = aapt ?? findAapt();
  Future<String> dump(List<String> args) async {
    final result = await Process.run(binary, args);
    if (result.exitCode != 0) {
      throw StateError('aapt 검사 실패: ${result.stderr}');
    }
    return result.stdout as String;
  }

  final permissions = await dump(['dump', 'permissions', apk]);
  final manifest = await dump(['dump', 'xmltree', apk, 'AndroidManifest.xml']);
  return {
    ...validateApkDump(permissions, manifest),
    'apk': File(apk).absolute.path,
    'apkBytes': File(apk).lengthSync(),
    'aapt': File(binary).absolute.path,
    'permissionsDump': permissions,
    'manifestDump': manifest,
  };
}

Future<void> main(List<String> args) async {
  try {
    var apk = 'build/app/outputs/apk/debug/app-debug.apk';
    String? report;
    String? aapt;
    for (var i = 0; i < args.length; i += 2) {
      if (i + 1 >= args.length) throw ArgumentError('옵션 값을 입력하세요.');
      switch (args[i]) {
        case '--apk':
          apk = args[i + 1];
        case '--report':
          report = args[i + 1];
        case '--aapt':
          aapt = args[i + 1];
        default:
          throw ArgumentError('알 수 없는 옵션: ${args[i]}');
      }
    }
    final result = await inspectApk(apk, aapt: aapt);
    if (report != null) {
      final file = File(report);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(result)}\n',
      );
    }
    stdout.writeln(
      jsonEncode({
        'status': result['status'],
        'apk': result['apk'],
        'permissions': result['permissions'],
        'allowBackup': result['allowBackup'],
      }),
    );
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
