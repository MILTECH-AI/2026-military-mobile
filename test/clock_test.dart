import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/clock.dart';

void main() {
  testWidgets('자정이 지나면 실행 중인 화면의 날짜를 갱신한다', (tester) async {
    var now = DateTime(2026, 11, 3, 23, 59, 59);
    final container = ProviderContainer(
      overrides: [wallClockProvider.overrideWithValue(() => now)],
    );
    final subscription = container.listen(currentTimeProvider, (_, _) {});
    expect(container.read(currentTimeProvider).day, 3);
    now = DateTime(2026, 11, 4);
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(currentTimeProvider), now);
    subscription.close();
    container.dispose();
  });

  testWidgets('백그라운드에서 날짜가 바뀌어도 복귀할 때 갱신한다', (tester) async {
    var now = DateTime(2026, 11, 3, 10);
    final container = ProviderContainer(
      overrides: [wallClockProvider.overrideWithValue(() => now)],
    );
    final subscription = container.listen(currentTimeProvider, (_, _) {});
    expect(container.read(currentTimeProvider).day, 3);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = DateTime(2026, 11, 5, 8);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(container.read(currentTimeProvider), now);
    subscription.close();
    container.dispose();
  });
}
