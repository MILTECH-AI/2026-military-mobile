import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/adaptive_runtime.dart';
import 'package:military_maintenance/data/model_execution.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';

import 'knowledge_import_test.dart'
    show bundleJson, fixtureVehicle, fixtureRule;
import 'ui_usability_test.dart' show setup, tap, reveal;
import 'data_tools_test.dart' show tapWithIo;

void main() {
  test('LLM은 런타임 API 요구 수준이 명시되고 충족될 때만 대상이 된다', () {
    const llm = ModelSpec(
      'test-llm',
      ModelTask.generation,
      ModelTier.generation,
      minAndroidApi: 28,
    );
    expect(llm.supportsApi(24), isFalse);
    expect(llm.supportsApi(28), isTrue);
    expect(llm.supportsApi(null), isFalse);
    expect(
      const ModelSpec(
        'unverified-llm',
        ModelTask.generation,
        ModelTier.generation,
      ).supportsApi(36),
      isFalse,
    );
  });
  testWidgets('정책으로 카메라가 차단돼도 수동 부품→근거·후보 이력→확인·정비 저장을 끝낸다', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AndroidModelWorker.channel,
          (call) async => call.method == 'capabilities'
              ? {
                  'totalRamBytes': 3221225472,
                  'availableRamBytes': 1073741824,
                  'cores': 4,
                  'abis': ['arm64-v8a'],
                  'androidApi': 24,
                  'freeStorageBytes': 4294967296,
                  'lowMemory': false,
                  'cameraStatus': 'disabled_policy',
                }
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidModelWorker.channel, null),
    );
    final s = await setup(tester);
    await tester.runAsync(() async {
      await s.registerVehicle(fixtureVehicle);
      await s.importKnowledge(KnowledgeBundle.decode(jsonEncode(bundleJson())));
      await s.updateSupportLibrary(
        (lib) => lib.copyWith(rules: [fixtureRule()]),
      );
      await s.addMaintenance(
        const Maintenance(
          id: 'MANUAL-HISTORY',
          vehicleId: 'RULE-TEST-1',
          date: '2026-10-01',
          part: 'fixture_filter',
          system: '엔진/연료',
          description: '가상 후보 이력',
          cost: 0,
        ),
      );
    });
    appRouter.go('/vision?vehicle=RULE-TEST-1&part=시험필터');
    await tester.pumpAndSettle();
    expect(find.text('카메라 사용 불가 · 수동 부품 선택'), findsOneWidget);
    expect(find.text('촬영 시작'), findsNothing);
    await tap(tester, find.byKey(const ValueKey('manual-part-support')));
    expect(appRouter.routeInformationProvider.value.uri.path, '/support');
    expect(find.textContaining('가상 지침'), findsWidgets);
    await reveal(tester, find.textContaining('가상 후보 이력'));
    expect(find.textContaining('부품 연결 미확인 후보 · 가상 후보 이력'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tap(tester, find.text('정비 결과 기록'));
    expect(find.textContaining('자동 확정하지 않습니다. 후보: 시험필터'), findsOneWidget);
    await tap(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == '부품 개념 선택',
      ),
    );
    await tester.tap(find.text('시험필터').last);
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('confirm-part-concept')));
    await tester.enterText(find.byKey(const ValueKey('정비내용')), '수동 선택 후 가상 점검');
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '0');
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () => s.records.any((r) => r.description == '수동 선택 후 가상 점검'),
    );
    final saved = s.records.singleWhere(
      (r) => r.description == '수동 선택 후 가상 점검',
    );
    expect(saved.confirmedConceptId, 'FILTER');
    expect(saved.inspectionId, isNull);
    appRouter.go('/entry?record=${saved.id}');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('confirm-part-concept')),
          )
          .value,
      isTrue,
    );
    await tap(tester, find.byKey(const ValueKey('수리부속 품명')));
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('confirm-part-concept')),
          )
          .value,
      isTrue,
    );
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '12');
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () => s.records.any((r) => r.id == saved.id && r.cost == 12),
    );
    expect(
      s.records.singleWhere((r) => r.id == saved.id).confirmedConceptId,
      'FILTER',
    );
    expect(tester.takeException(), isNull);
  });
}
