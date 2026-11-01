import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/main.dart';
import 'package:military_maintenance/data/store.dart';

import 'ui_usability_test.dart' show setup, tap, reveal;
import 'data_tools_test.dart' show tapWithIo;
import 'knowledge_import_test.dart' show bundleJson, fixtureVehicle;

void main() {
  testWidgets('반입 자료·적용조건 대화상자·독립 주기 판정은 600×800 큰 글자에서도 사용 가능하다', (
    tester,
  ) async {
    final s = await setup(tester, size: const Size(600, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(() async {
      await s.registerVehicle(fixtureVehicle);
      await s.importKnowledge(KnowledgeBundle.decode(jsonEncode(bundleJson())));
    });
    appRouter.go('/support?vehicle=RULE-TEST-1&part=시험필터');
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('service-policy-unselected')));
    await tester.tap(find.text('가혹').last);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tap(tester, find.text('지침 적용·교환 기준 확인'));
    expect(tester.takeException(), isNull);
    await tap(tester, find.byType(CheckboxListTile));
    await tapWithIo(
      tester,
      find.byKey(const ValueKey('save-knowledge-rule')),
      completed: () => s.supportLibrary.rules.isNotEmpty,
    );
    await reveal(tester, find.byKey(const ValueKey('service-as-of')));
    expect(
      s.serviceDistance(s.supportLibrary.rules.single).remainingKm,
      isNull,
    );
    expect(
      s.serviceDistance(s.supportLibrary.rules.single).calendarDue,
      isNull,
    );
    expect(find.textContaining('가상가혹지침.pdf · PDF 2쪽'), findsOneWidget);
    expect(find.textContaining('거리 500 km · 기간 6개월'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/knowledge_flow_large_text.png'),
    );
  });
  testWidgets('로컬 파일 반입 미리보기·검토 대기·차량 적용 확인·부대 기준 선택을 기존 화면에서 연결한다', (
    tester,
  ) async {
    final s = await setup(tester, size: const Size(1280, 960));
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('knowledge-ui-fixture-'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    final input = File('${dir.path}/fixture.json');
    await tester.runAsync(() => input.writeAsString(jsonEncode(bundleJson())));
    const channel = MethodChannel('maintenance/local_files');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'pickBackup' ? input.path : true,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.runAsync(() => s.registerVehicle(fixtureVehicle));
    final count = s.records.length;
    appRouter.go('/data-tools');
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('import-knowledge'));
    await reveal(tester, button);
    await tester.runAsync(() => tester.tap(button));
    for (
      var i = 0;
      i < 200 && find.byType(AlertDialog).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.text('정비 자료 반입 검토'), findsOneWidget);
    expect(s.supportLibrary.knowledge.imports, isEmpty);
    await tapWithIo(
      tester,
      find.byKey(const ValueKey('confirm-knowledge-import')),
      completed: () => s.supportLibrary.knowledge.imports.isNotEmpty,
    );
    expect(s.records.length, count);
    expect(s.supportLibrary.knowledge.pending.length, 1);
    expect(s.searchEvidence(fixtureVehicle.id, '시험필터', ''), isEmpty);
    appRouter.go('/support?vehicle=RULE-TEST-1&part=시험필터');
    await tester.pumpAndSettle();
    await tap(tester, find.text('지침 적용·교환 기준 확인'));
    await tap(tester, find.byType(CheckboxListTile));
    await tapWithIo(
      tester,
      find.byKey(const ValueKey('save-knowledge-rule')),
      completed: () => s.supportLibrary.rules.isNotEmpty,
    );
    expect(s.searchEvidence(fixtureVehicle.id, '시험필터', '').length, 1);
    await tap(tester, find.byKey(const ValueKey('service-policy-unselected')));
    await tester.tap(find.text('일반').last);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(s.serviceDistance(s.supportLibrary.rules.single).policy, 'normal');
    expect(
      s.serviceDistance(s.supportLibrary.rules.single).remainingKm,
      isNull,
    );
    expect(
      s.serviceDistance(s.supportLibrary.rules.single).calendarDue,
      isNull,
    );
    await tap(tester, find.text('지침 적용·교환 기준 확인'));
    await tester.enterText(
      find.byKey(const ValueKey('knowledge-baseline-km')),
      '1000',
    );
    await tester.enterText(
      find.byKey(const ValueKey('knowledge-baseline-date')),
      '2025-10-01',
    );
    await tapWithIo(
      tester,
      find.byKey(const ValueKey('save-knowledge-rule')),
      completed: () => s.supportLibrary.rules.single.baselineKm == 1000,
    );
    final result = s.serviceDistance(s.supportLibrary.rules.single);
    expect(result.remainingKm, 0);
    expect(result.remainingDays, isNegative);
    expect(result.firstDue, contains('둘 다 도래'));
    await reveal(tester, find.byKey(const ValueKey('service-as-of')));
    expect(find.textContaining('선도래 순서 확인 불가'), findsWidgets);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/knowledge_flow_1280x960.png'),
    );
  });
}
