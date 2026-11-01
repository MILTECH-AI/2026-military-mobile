// End-to-end workflow review. Camera acquisition is represented by an explicit
// fixture; physical camera and human usability claims are outside this test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';

import '../test/ui_usability_test.dart' show setup, tap, reveal;
import '../test/data_tools_test.dart' show tapWithIo;

final results = <Map<String, dynamic>>[];
void main() {
  tearDownAll(() {
    Directory('output/workflow-review').createSync(recursive: true);
    File('output/workflow-review/results.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'method': 'Simulated user tasks; in-memory DB; fixture inspection, not a live camera test.',
        'applicationChanged': false,
        'results': results,
      }),
    );
  });

  testWidgets('처음 실행한 사용자가 차량 선택·지원 검색·정비계획을 시작한다', (tester) async {
    final s = await setup(tester);
    expect(s.supportLibrary.evidence, isEmpty);
    expect(s.supportLibrary.rules, isEmpty);
    await tap(tester, find.widgetWithText(FilledButton, 'AI 정비지원'));
    final vehicleField = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).first,
    );
    final automaticVehicle = vehicleField.initialValue;
    await tester.enterText(
      find.byKey(const ValueKey('support-query')),
      '시동이 걸리지 않아요',
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        '문서 근거 0건 · 관련 이력 ${s.relatedMaintenance(automaticVehicle!, '', '시동이 걸리지 않아요').length}건',
      ),
      findsOneWidget,
    );
    await tap(tester, find.widgetWithText(OutlinedButton, '연간 정비계획'));
    expect(find.text('등록된 정비 주기가 없습니다.'), findsOneWidget);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('../output/workflow-review/01-first-use-no-plan.png'),
    );
    appRouter.go('/vehicles');
    await tester.pumpAndSettle();
    expect(find.text('차량 등록'), findsNothing);
    results.add({
      'task': 'first_use',
      'vehicleCount': s.vehicles.length,
      'allVehiclesAreMock': s.vehicles.every((v) => v.id.startsWith('MOCK-')),
      'vehicleAutomaticallySelected': automaticVehicle,
      'evidenceCount': 0,
      'ruleCount': 0,
      'vehicleRegistrationActionVisible': false,
      'blocker': 'No initial real vehicle registration or prepared manuals/maintenance rules; user must configure support data.',
    });
  });

  testWidgets('차량·부품 점검에서 정비 등록 후 다음 정비계획까지 완료한다', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    final rule = MaintenanceRule(
      id: 'WORKFLOW-RULE',
      vehicleId: v.id,
      part: '엔진오일',
      intervalKm: 5000,
      baselineKm: v.distance - 6000,
      baselineDate: '2026-10-01',
      source: '시험용 교환 주기',
    );
    await tester.runAsync(() async {
      await s.saveSupportLibrary(
        SupportLibrary(
          rules: [rule],
          evidence: [
            MaintenanceEvidence(
              id: 'WORKFLOW-DOC',
              model: v.model,
              part: '엔진오일',
              symptoms: '교환',
              title: '시험용 근거',
              location: '1쪽',
              text: '업무 흐름 확인용 가상 근거',
            ),
          ],
        ),
      );
      await s.saveInspection(
        Inspection(
          id: 'WORKFLOW-PHOTO',
          vehicleId: v.id,
          area: '엔진오일',
          mode: '부품 촬영',
          created: '2026-10-09T10:00:00',
          imagePath: File('assets/figma/ed09d.png').absolute.path,
          note: '업무 흐름 검증을 위한 가상 점검 메모',
        ),
      );
    });
    final before = s.serviceDistance(rule);
    expect(before.remainingKm, 0);
    appRouter.go('/vehicles');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), v.id);
    await tester.pumpAndSettle();
    await tap(tester, find.widgetWithText(TextButton, v.id));
    await tap(tester, find.widgetWithText(OutlinedButton, 'AI 정비지원'));
    // Inspect a saved session from the support screen as a user would.
    final session = find.widgetWithText(ListTile, '엔진오일 · 2026-10-09');
    await tap(tester, session);
    expect(
      appRouter.routeInformationProvider.value.uri.queryParameters['session'],
      'WORKFLOW-PHOTO',
    );
    await tap(tester, find.text('정비 기록 등록'));
    final partField = find.byKey(const ValueKey('수리부속 품명'));
    final detailField = find.byKey(const ValueKey('정비내용'));
    final emptyPart = tester.widget<TextFormField>(partField).controller!.text;
    final emptyDescription = tester
        .widget<TextFormField>(detailField)
        .controller!
        .text;
    expect(emptyPart, isEmpty);
    expect(emptyDescription, isEmpty);
    await tester.enterText(partField, '엔진오일');
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '50000');
    await tester.enterText(detailField, '업무 흐름 시험: 엔진오일 교환 완료');
    await tap(tester, find.byKey(const ValueKey('system-냉각')));
    await tap(tester, find.text('엔진/연료').last);
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () =>
          s.records.any((r) => r.description == '업무 흐름 시험: 엔진오일 교환 완료'),
    );
    expect(find.textContaining('정상적으로 등록되었습니다.'), findsOneWidget);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('../output/workflow-review/02-maintenance-saved.png'),
    );
    final record = s.records.firstWhere(
      (r) => r.description == '업무 흐름 시험: 엔진오일 교환 완료',
    );
    final after = s.serviceDistance(rule);
    expect(after.remainingKm, isNull);
    expect(after.reason, contains('갱신'));
    appRouter.go('/plans?vehicle=${v.id}');
    await tester.pumpAndSettle();
    expect(find.textContaining('기준일 이후 정비 이력이 있습니다.'), findsOneWidget);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile(
        '../output/workflow-review/03-plan-after-completion.png',
      ),
    );
    results.add({
      'task': 'inspection_to_completion',
      'vehicle': v.id,
      'part': '엔진오일',
      'inspectionFixtureUsed': true,
      'entryPartAfterInspection': emptyPart,
      'entryNoteAfterInspection': emptyDescription,
      'maintenanceSaved': true,
      'recordFields': record.toJson().keys.toList(),
      'remainingBeforeMaintenance': before.remainingKm,
      'remainingAfterMaintenance': after.remainingKm,
      'planAfterMaintenance': after.reason,
      'ruleBaselineAfterMaintenance':
          s.supportLibrary.rules.single.baselineDate,
      'blocker': 'Maintenance save does not carry inspection context or finish the service cycle; last-change baseline requires a separate manual update.',
    });
  });
}
