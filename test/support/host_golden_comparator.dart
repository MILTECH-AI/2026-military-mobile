import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';

/// Keep exact pixel comparisons within the same native font renderer.
class HostGoldenComparator extends LocalFileComparator {
  HostGoldenComparator(super.testFile, {String? hostAbi})
    : hostAbi = hostAbi ?? Abi.current().toString();

  final String hostAbi;

  @override
  Uri getTestUri(Uri key, int? version) {
    final uri = super.getTestUri(key, version);
    // Preserve the legacy references used by the original Windows workflow.
    if (hostAbi == 'windows_x64' || !uri.path.startsWith('goldens/')) {
      return uri;
    }
    return uri.replace(
      path: uri.path.replaceFirst('goldens/', 'goldens/$hostAbi/'),
    );
  }
}
