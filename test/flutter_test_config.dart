import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/host_golden_comparator.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final previous = goldenFileComparator;
  if (previous is LocalFileComparator) {
    goldenFileComparator = HostGoldenComparator(
      previous.basedir.resolve('flutter_test_config.dart'),
    );
  }
  // testMain registers tests; they run after it returns. Keep this comparator
  // for the test isolate's entire lifetime.
  await testMain();
}
