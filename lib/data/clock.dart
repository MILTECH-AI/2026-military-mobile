import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final wallClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// UI date source; tests override this so rendered reference images stay stable.
final currentTimeProvider = Provider<DateTime>((ref) {
  final now = ref.watch(wallClockProvider)();
  final midnight = DateTime(now.year, now.month, now.day + 1);
  final timer = Timer(midnight.difference(now), ref.invalidateSelf);
  final observer = _DateObserver(ref.invalidateSelf);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() {
    timer.cancel();
    WidgetsBinding.instance.removeObserver(observer);
  });
  return now;
});

class _DateObserver extends WidgetsBindingObserver {
  _DateObserver(this.refresh);
  final void Function() refresh;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }
}
