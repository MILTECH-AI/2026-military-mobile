import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';
import 'package:military_maintenance/ui/components.dart';

import 'ui_usability_test.dart' show setup, tap;

void main() {
  testWidgets('예제 시작과 합성 분석을 분리하고 준비·업무 동선을 제공한다', (tester) async {
    await setup(tester);
    expect(find.textContaining('예제 데이터 보기'), findsOneWidget);
    expect(find.text('예제 차량'), findsOneWidget);
    expect(find.byType(StatusRing), findsNothing);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/workflow_home_demo_1280x800.png'),
    );
    await tap(tester, find.text('실사용 준비·차량 등록'));
    expect(find.text('준비 상태'), findsOneWidget);
    expect(find.text('차량 등록 미등록'), findsOneWidget);
    expect(find.text('정비 근거 미등록'), findsOneWidget);
    expect(find.text('정비 주기 미등록'), findsOneWidget);
    appRouter.go('/');
    await tester.pumpAndSettle();
    await tap(tester, find.text('예제 분석 보기'));
    expect(find.byType(StatusRing), findsOneWidget);
  });

  testWidgets('실제 등록 차량의 주기 도달·기준 확인·미등록을 구분하고 작업 대상을 연결한다', (tester) async {
    final s = await setup(tester, size: const Size(1280, 960));
    await tester.runAsync(() async {
      for (final id in ['HOME-REAL-A', 'HOME-REAL-B']) {
        await s.registerVehicle(
          Vehicle(
            id: id,
            model: '홈 구성 시험차',
            year: 2020,
            distance: 20000,
            hours: 500,
            fuel: 1000,
            risk: 0,
          ),
        );
      }
      await s.saveSupportLibrary(
        const SupportLibrary(
          rules: [
            MaintenanceRule(
              id: 'DUE',
              vehicleId: 'HOME-REAL-A',
              part: '엔진오일',
              intervalKm: 5000,
              baselineKm: 13000,
              baselineDate: '2026-10-09',
              source: '가상 시험 지침',
            ),
            MaintenanceRule(
              id: 'CHECK',
              vehicleId: 'HOME-REAL-A',
              part: '브레이크패드',
              intervalKm: 10000,
              baselineKm: 10000,
              baselineDate: '2026-10-01',
              source: '가상 시험 지침',
            ),
          ],
        ),
      );
      await s.addMaintenance(
        const Maintenance(
          id: 'UNKNOWN',
          vehicleId: 'HOME-REAL-A',
          date: '2026-10-09',
          part: 'brake_pad',
          system: '제동',
          description: '교환 여부가 미확인인 과거 시험 기록',
          cost: 0,
        ),
      );
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('등록 차량 2대 기준'), findsOneWidget);
    expect(find.text('2대'), findsOneWidget);
    expect(find.text('1항목'), findsNWidgets(2));
    expect(find.text('1대'), findsOneWidget);
    expect(find.byType(StatusRing), findsNothing);
    expect(find.text('낮음'), findsNothing);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/workflow_home_registered_1280x960.png'),
    );
    await tap(tester, find.widgetWithText(ListTile, 'HOME-REAL-A · 브레이크패드'));
    final uri = appRouter.routeInformationProvider.value.uri;
    expect(uri.path, '/support');
    expect(uri.queryParameters['vehicle'], 'HOME-REAL-A');
    expect(uri.queryParameters['part'], '브레이크패드');
  });

  testWidgets('정비지원에서 촬영 없이 선택한 부품의 작업 기록으로 이동한다', (tester) async {
    final s = await setup(tester);
    final vehicle = s.vehicles.first.id;
    appRouter.go('/support?vehicle=$vehicle&part=brake_pad');
    await tester.pumpAndSettle();
    final before = s.records.length;
    await tap(tester, find.widgetWithText(OutlinedButton, '정비 결과 기록'));
    final uri = appRouter.routeInformationProvider.value.uri;
    expect(uri.path, '/entry');
    expect(uri.queryParameters['vehicle'], vehicle);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('수리부속 품명')))
          .controller!
          .text,
      '브레이크패드',
    );
    expect(s.records.length, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('재구성한 홈을 600×800·글자 1.6배에서 사용할 수 있다', (tester) async {
    await setup(tester, size: const Size(600, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tap(tester, find.widgetWithText(OutlinedButton, 'AI 정비지원'));
    expect(appRouter.routeInformationProvider.value.uri.path, '/support');
    expect(tester.takeException(), isNull);
  });
}
