import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';
import 'package:military_maintenance/ui/components.dart';

import 'ui_usability_test.dart' show setup, tap;

const registered = Vehicle(
  id: 'SCOPE-REAL',
  model: '가상 등록 시험차',
  year: 2020,
  distance: 20000,
  hours: 500,
  fuel: 1000,
  risk: 0,
);

void main() {
  testWidgets('등록 차량이 한 대이고 비용이 없어도 분석 순위에 예제가 섞이지 않는다', (tester) async {
    final s = await setup(tester);
    await tester.runAsync(() => s.registerVehicle(registered));
    appRouter.go('/analysis');
    await tester.pumpAndSettle();
    expect(find.text('조회 대상: 등록 차량 1대 · 합성 고장확률 미적용'), findsOneWidget);
    final panel = find.widgetWithText(Panel, '정비 비용 상위 차량');
    await tester.ensureVisible(panel);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: panel, matching: find.text('SCOPE-REAL')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.textContaining('MOCK-')),
      findsNothing,
    );
  });

  testWidgets('각 업무 화면은 선택한 예제 차량과 등록 차량을 구분한다', (tester) async {
    final s = await setup(tester);
    final mock = s.vehicles.first.id;
    final mockRecord = s.records.firstWhere((r) => r.vehicleId == mock).id;
    for (final route in [
      '/vehicles',
      '/vehicles/$mock',
      '/records',
      '/records/$mockRecord',
      '/analysis',
      '/entry?vehicle=$mock',
      '/vision?vehicle=$mock',
      '/support?vehicle=$mock',
      '/chat?vehicle=$mock',
      '/plans?vehicle=$mock',
      '/ai-history?vehicle=$mock',
      '/data-tools',
    ]) {
      appRouter.go(route);
      await tester.pumpAndSettle();
      expect(find.byType(DataScopeNotice), findsWidgets, reason: route);
      expect(find.textContaining('예제 차량'), findsWidgets, reason: route);
      expect(tester.takeException(), isNull, reason: route);
    }
    await tester.runAsync(() => s.registerVehicle(registered));
    for (final route in [
      '/vehicles',
      '/vehicles/SCOPE-REAL',
      '/records',
      '/analysis',
      '/entry?vehicle=SCOPE-REAL',
      '/vision?vehicle=SCOPE-REAL',
      '/support?vehicle=SCOPE-REAL',
      '/plans?vehicle=SCOPE-REAL',
      '/ai-history?vehicle=SCOPE-REAL',
    ]) {
      appRouter.go(route);
      await tester.pumpAndSettle();
      expect(
        find.text('조회 대상: 등록 차량 1대 · 합성 고장확률 미적용'),
        findsOneWidget,
        reason: route,
      );
      expect(tester.takeException(), isNull, reason: route);
    }
  });

  testWidgets('예제 함께 보기와 지원 대상 변경에 따라 구분 표시가 갱신된다', (tester) async {
    final s = await setup(tester);
    final mock = s.vehicles.first;
    await tester.runAsync(() => s.registerVehicle(registered));
    appRouter.go('/vehicles');
    await tester.pumpAndSettle();
    await tap(tester, find.text('예제 차량 함께 보기'));
    expect(find.textContaining('등록 차량 1대 · 예제 차량 100대 혼합'), findsOneWidget);
    appRouter.go('/support?vehicle=SCOPE-REAL');
    await tester.pumpAndSettle();
    final field = find.widgetWithText(
      DropdownButtonFormField<String>,
      '차량 / 차종',
    );
    await tap(tester, field);
    final item = find.text('${mock.id} · ${mock.model}');
    await tester.scrollUntilVisible(
      item,
      -300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DropdownButtonFormField<String>>(field).initialValue,
      mock.id,
    );
    tester.widget<ListView>(find.byType(ListView).last).controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('조회 대상: 예제 차량 1대 · 실사용 자료와 구분'), findsOneWidget);
  });
}
