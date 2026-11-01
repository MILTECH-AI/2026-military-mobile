import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';
import 'package:military_maintenance/ui/data_tools.dart';

import 'app_test.dart' show mount;

Future<void> tapWithIo(
  WidgetTester tester,
  Finder finder, {
  bool Function()? completed,
}) async {
  await tester.runAsync(() => tester.tap(finder));
  final watch = Stopwatch()..start();
  var settled = false;
  while (watch.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    final loading =
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    if (watch.elapsedMilliseconds > 100 &&
        !loading &&
        (completed == null || completed())) {
      settled = true;
      break;
    }
  }
  expect(settled, isTrue, reason: 'UI action did not complete');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('운용 기록 다음 페이지에서 과거 기록을 열고 변경 전후 이력을 확인한다', (tester) async {
    final s = await mount(tester, const Size(1440, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appRouter.go('/data-tools');
    await tester.pumpAndSettle();
    final id = tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .initialValue!;
    final rows = s.operations.where((r) => r['vehicleId'] == id).toList()
      ..sort(
        (a, b) => (b['created'] as String).compareTo(a['created'] as String),
      );
    final next = find.byKey(const ValueKey('operations-next'));
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    await tester.pumpAndSettle();
    final old = rows[12];
    final edit = find.byKey(ValueKey('edit-op-${old['id']}'));
    expect(edit, findsOneWidget);
    await tester.ensureVisible(edit);
    await tester.pumpAndSettle();
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.text('운용 기록 수정'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => s.editOperation(
        old['id'] as String,
        (old['distance'] as int) + 1,
        old['hours'] as int,
        old['fuel'] as int,
      ),
    );
    await tester.pumpAndSettle();
    final logs = await tester.runAsync(() => s.recordChanges(id));
    final change = find.byKey(ValueKey('change-${logs!.rows.first['id']}'));
    final outer = find
        .descendant(
          of: find.byType(DataToolsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('수정·삭제 이력'),
      300,
      scrollable: outer,
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(change);
    await tester.pumpAndSettle();
    await tapWithIo(tester, change);
    expect(find.text('변경 전후 비교'), findsOneWidget);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/change-history_1440x1080.png'),
    );
    expect(
      find.textContaining(
        '${old['distance']} → ${(old['distance'] as int) + 1}',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() => s.db!.close());
  });
  testWidgets('운용 관리 화면에서 누적값 수정과 최신 기록 삭제를 반영한다', (tester) async {
    final s = await mount(tester, const Size(1440, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appRouter.go('/data-tools');
    await tester.pumpAndSettle();
    final selected = tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .initialValue!;
    final row = s.operations.firstWhere((r) => r['vehicleId'] == selected);
    await tester.ensureVisible(find.byKey(ValueKey('edit-op-${row['id']}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('edit-op-${row['id']}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('edit-distance')),
      '${(row['distance'] as int) + 100}',
    );
    await tester.enterText(
      find.byKey(const ValueKey('edit-hours')),
      '${(row['hours'] as int) + 5}',
    );
    await tester.enterText(
      find.byKey(const ValueKey('edit-fuel')),
      '${(row['fuel'] as int) + 10}',
    );
    await tapWithIo(
      tester,
      find.text('수정 저장'),
      completed: () =>
          s.vehicle(selected).distance == (row['distance'] as int) + 100,
    );
    expect(s.vehicle(selected).distance, (row['distance'] as int) + 100);
    tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(DataToolsScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('운용 기록을 수정했습니다. 집계와 예측을 갱신했습니다.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(ValueKey('delete-op-${row['id']}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('delete-op-${row['id']}')));
    await tester.pumpAndSettle();
    await tapWithIo(
      tester,
      find.text('삭제'),
      completed: () => !s.operations.any((r) => r['id'] == row['id']),
    );
    expect(s.operations.any((r) => r['id'] == row['id']), isFalse);
    tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(DataToolsScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('운용 기록을 삭제했습니다. 집계와 예측을 갱신했습니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await s.db!.close();
  });
  testWidgets('정비 상세에서 수정·삭제를 확인하고 화면과 예측에 반영한다', (tester) async {
    final s = await mount(tester, const Size(1440, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final value = Maintenance(
      id: s.newId('MR'),
      vehicleId: 'MOCK-RX-0001',
      date: '2026-10-09',
      part: '시험 호스',
      system: '냉각',
      description: '가상 수정 시험',
      cost: 12000,
      maintenanceType: '고장수리',
    );
    await tester.runAsync(() => s.addMaintenance(value));
    appRouter.go('/records/${value.id}');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-maintenance')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '26000');
    await tester.ensureVisible(find.text('저장'));
    await tester.pumpAndSettle();
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () =>
          s.records.singleWhere((r) => r.id == value.id).cost == 26000,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    expect(s.records.singleWhere((r) => r.id == value.id).cost, 26000);
    expect(s.predictions[value.vehicleId]!['trigger'], '정비 수정');
    appRouter.go('/records/${value.id}');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-maintenance')));
    await tester.pumpAndSettle();
    await tapWithIo(tester, find.text('취소'));
    await tester.pumpAndSettle();
    expect(s.records.any((r) => r.id == value.id), isTrue);
    await tester.tap(find.byKey(const ValueKey('delete-maintenance')));
    await tester.pumpAndSettle();
    await tapWithIo(
      tester,
      find.text('삭제'),
      completed: () =>
          !s.records.any((r) => r.id == value.id) &&
          s.predictions[value.vehicleId]!['trigger'] == '정비 삭제',
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    expect(s.records.any((r) => r.id == value.id), isFalse);
    expect(s.predictions[value.vehicleId]!['trigger'], '정비 삭제');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await s.db!.close();
  });

  testWidgets('백업 저장과 복원 취소·확인은 시스템 파일 채널과 연결된다', (tester) async {
    final s = await mount(tester, const Size(1440, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('backup-ui-'),
    );
    addTearDown(() => dir!.delete(recursive: true));
    final backup = File('${dir!.path}/snapshot.mbackup');
    await tester.runAsync(() => s.exportBackup(backup));
    final baseline = s.records.length;
    await tester.runAsync(
      () => s.addMaintenance(
        Maintenance(
          id: 'RESTORE-UI',
          vehicleId: 'MOCK-RX-0001',
          date: '2026-10-09',
          part: '가상 시험',
          system: '냉각',
          description: '복원 확인',
          cost: 1000,
        ),
      ),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
    messenger.setMockMethodCallHandler(NativeBackupFiles.channel, (call) async {
      if (call.method == 'pickBackup') return backup.path;
      if (call.method == 'releaseBackup') return true;
      final args = call.arguments as Map;
      expect(await File(args['path'] as String).exists(), isTrue);
      expect(args['name'], endsWith('.mbackup'));
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(NativeBackupFiles.channel, null);
    });
    appRouter.go('/data-tools');
    await tester.pumpAndSettle();
    await tapWithIo(tester, find.byKey(const ValueKey('export-backup')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pumpAndSettle();
    expect(find.text('백업 파일을 저장했습니다. 선택한 위치에서 확인해 주세요.'), findsOneWidget);
    await tapWithIo(tester, find.byKey(const ValueKey('import-backup')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    expect(find.text('백업으로 현재 데이터 교체'), findsOneWidget);
    await tapWithIo(tester, find.text('취소'));
    await tester.pumpAndSettle();
    expect(s.records.length, baseline + 1);
    await tapWithIo(tester, find.byKey(const ValueKey('import-backup')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    await tapWithIo(
      tester,
      find.byKey(const ValueKey('confirm-restore')),
      completed: () => s.records.length == baseline,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pumpAndSettle();
    expect(s.records.length, baseline);
    expect(find.text('기록과 점검 사진을 복원했습니다. 집계와 예측을 갱신했습니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await s.db!.close();
  });
}
