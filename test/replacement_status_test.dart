import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';

import 'ui_usability_test.dart' show setup, tap, reveal;
import 'data_tools_test.dart' show tapWithIo;

const testVehicle = Vehicle(
  id: 'UI-TEST-001',
  model: '가상 상태 시험차',
  year: 2020,
  distance: 20000,
  hours: 500,
  fuel: 1000,
  risk: 0,
);

Maintenance record(
  String id,
  bool? state, {
  String date = '2026-10-01',
  String part = '엔진오일',
}) => Maintenance(
  id: id,
  vehicleId: testVehicle.id,
  date: date,
  part: part,
  system: '엔진/연료',
  description: '가상 시험 기록 $id',
  cost: 1000,
  replacementCompleted: state,
  odometerKm: state == true ? 20000 : null,
);

Future<void> chooseStatus(WidgetTester tester, String label) async {
  await tap(tester, find.byKey(const ValueKey('replacement-completed')));
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final state in <bool?>[null, false, true]) {
    testWidgets(
      '${replacementStatusLabel(state)} 기록에서 교환 여부를 건드리지 않은 수정은 DB 재조회 후에도 유지된다',
      (tester) async {
        final s = await setup(tester, size: const Size(1280, 960));
        await tester.runAsync(() async {
          await s.registerVehicle(testVehicle);
          await s.addMaintenance(record('UNCHANGED', state));
        });
        appRouter.go('/entry?record=UNCHANGED');
        await tester.pumpAndSettle();
        final selector = find.byKey(const ValueKey('replacement-completed'));
        await reveal(tester, selector);
        expect(
          tester.widget<DropdownButtonFormField<String>>(selector).initialValue,
          state == null
              ? 'unknown'
              : state
              ? 'completed'
              : 'none',
        );
        await tester.enterText(find.byKey(const ValueKey('가격(원)')), '1200');
        await reveal(tester, find.text('저장'));
        await tapWithIo(
          tester,
          find.text('저장'),
          completed: () =>
              s.records.any((r) => r.id == 'UNCHANGED' && r.cost == 1200),
        );
        final saved = s.records.singleWhere((r) => r.id == 'UNCHANGED');
        expect(saved.replacementCompleted, state);
        expect(saved.odometerKm, state == true ? 20000 : null);
        appRouter.go('/records/UNCHANGED');
        await tester.pumpAndSettle();
        expect(find.text(replacementStatusLabel(state)), findsOneWidget);
        appRouter.go('/entry?record=UNCHANGED');
        await tester.pumpAndSettle();
        await reveal(tester, selector);
        expect(
          tester.widget<DropdownButtonFormField<String>>(selector).initialValue,
          state == null
              ? 'unknown'
              : state
              ? 'completed'
              : 'none',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('보류 원인 전부를 보여주고 확인하기에서 명시적으로 처리하며 남은 기록은 계속 보류한다', (
    tester,
  ) async {
    final s = await setup(tester, size: const Size(1280, 960));
    const rule = MaintenanceRule(
      id: 'UI-RULE',
      vehicleId: 'UI-TEST-001',
      part: '엔진오일',
      intervalKm: 5000,
      baselineKm: 13000,
      baselineDate: '2026-09-01',
      source: '가상 주기',
    );
    await tester.runAsync(() async {
      await s.registerVehicle(testVehicle);
      await s.saveSupportLibrary(const SupportLibrary(rules: [rule]));
      for (final r in [
        record('B', null),
        record('A', null),
        record('OLD', null, date: '2026-08-31'),
        record('OTHER', null, part: '배터리'),
      ]) {
        await s.addMaintenance(r);
      }
    });
    expect(s.serviceDistance(rule).blockingRecordIds, ['A', 'B']);
    appRouter.go('/plans?vehicle=UI-TEST-001');
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('resolve-maintenance-A')));
    expect(find.byKey(const ValueKey('resolve-maintenance-B')), findsOneWidget);
    expect(find.byKey(const ValueKey('resolve-maintenance-OLD')), findsNothing);
    expect(
      find.byKey(const ValueKey('resolve-maintenance-OTHER')),
      findsNothing,
    );
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/replacement_hold_1280x960.png'),
    );
    await tap(tester, find.byKey(const ValueKey('resolve-maintenance-A')));
    expect(
      appRouter.routeInformationProvider.value.uri.queryParameters['record'],
      'A',
    );
    await chooseStatus(tester, '교환 없음');
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () =>
          s.records.singleWhere((r) => r.id == 'A').replacementCompleted ==
          false,
    );
    expect(s.serviceDistance(rule).remainingKm, isNull);
    expect(s.serviceDistance(rule).blockingRecordIds, ['B']);
    appRouter.go('/support?vehicle=UI-TEST-001&part=엔진오일');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('resolve-maintenance-A')), findsNothing);
    await tap(tester, find.byKey(const ValueKey('resolve-maintenance-B')));
    await chooseStatus(tester, '교환 완료');
    await tester.enterText(
      find.byKey(const ValueKey('교환 당시 누적 주행거리(km)')),
      '20000',
    );
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () =>
          s.records.singleWhere((r) => r.id == 'B').replacementCompleted ==
          true,
    );
    expect(s.serviceDistance(rule).remainingKm, 5000);
    expect(s.serviceDistance(rule).blockingRecordIds, isEmpty);
    // An explicit correction to unknown must restore the hold.
    appRouter.go('/support?vehicle=UI-TEST-001&part=엔진오일');
    await tester.pumpAndSettle();
    appRouter.go('/entry?record=B');
    await tester.pumpAndSettle();
    await chooseStatus(tester, '미확인');
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () =>
          s.records.singleWhere((r) => r.id == 'B').replacementCompleted ==
          null,
    );
    expect(s.serviceDistance(rule).remainingKm, isNull);
    expect(s.serviceDistance(rule).blockingRecordIds, ['B']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('600×800 큰 글자에서도 미확인 선택과 종합현황 확인하기를 사용할 수 있다', (tester) async {
    final s = await setup(tester, size: const Size(600, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const rule = MaintenanceRule(
      id: 'SMALL-RULE',
      vehicleId: 'UI-TEST-001',
      part: '엔진오일',
      intervalKm: 5000,
      baselineKm: 13000,
      baselineDate: '2026-09-01',
      source: '가상 주기',
    );
    await tester.runAsync(() async {
      await s.registerVehicle(testVehicle);
      await s.saveSupportLibrary(const SupportLibrary(rules: [rule]));
      await s.addMaintenance(record('SMALL', null));
    });
    appRouter.go('/entry?record=SMALL');
    await tester.pumpAndSettle();
    await chooseStatus(tester, '교환 완료');
    await reveal(tester, find.byKey(const ValueKey('교환 당시 누적 주행거리(km)')));
    expect(tester.takeException(), isNull);
    await chooseStatus(tester, '미확인');
    expect(tester.takeException(), isNull);
    appRouter.go('/');
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('resolve-maintenance-SMALL'));
    await reveal(tester, action);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/replacement_hold_large_text.png'),
    );
    await tap(tester, action);
    expect(
      appRouter.routeInformationProvider.value.uri.queryParameters['record'],
      'SMALL',
    );
    expect(tester.takeException(), isNull);
  });
}
