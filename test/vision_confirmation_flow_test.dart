import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/adaptive_runtime.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';

import 'knowledge_import_test.dart'
    show bundleJson, fixtureVehicle, fixtureRule;
import 'ui_usability_test.dart' show setup, tap, reveal;
import 'data_tools_test.dart' show tapWithIo;

void main() {
  testWidgets('공개 Vision 미매핑·카메라 차단 상태에서 수동 개념 확인 후 근거와 정비 등록으로 이어진다', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AndroidModelWorker.channel,
          (call) async => switch (call.method) {
            'capabilities' => {
              'totalRamBytes': 3221225472,
              'availableRamBytes': 1073741824,
              'cores': 2,
              'abis': ['x86_64'],
              'androidApi': 33,
              'freeStorageBytes': 4294967296,
              'lowMemory': false,
              'cameraStatus': 'disabled_policy',
            },
            'modelInfo' => {
              'optionalModels': [
                {
                  'installed': true,
                  'supportedAbi': true,
                  'modelId': 'ssd-mobilenet-int8-public-v1',
                },
              ],
            },
            _ => null,
          },
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
      await s.saveInspection(
        const Inspection(
          id: 'DEMO-PHOTO',
          vehicleId: 'RULE-TEST-1',
          area: '미지정',
          mode: '가상 시험',
          created: '2026-10-09T12:00:00',
          imagePath: 'missing-fixture.png',
          note: '가상 점검',
        ),
      );
    });
    appRouter.go('/vision?vehicle=RULE-TEST-1&session=DEMO-PHOTO');
    await tester.pumpAndSettle();
    await tap(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == '부품 개념 수동 선택',
      ),
    );
    await tester.tap(find.text('시험필터').last);
    await tester.pumpAndSettle();
    expect(s.inspections.single.confirmedConceptId, isNull);
    final button = find.byKey(const ValueKey('vision-save-concept'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tap(tester, find.byKey(const ValueKey('vision-confirm-concept')));
    await tapWithIo(
      tester,
      button,
      completed: () => s.inspections.single.confirmedConceptId == 'FILTER',
    );
    expect(s.inspections.single.area, '시험필터');
    await tap(tester, find.text('확인한 부품 → 근거·이력 조회'));
    expect(appRouter.routeInformationProvider.value.uri.path, '/support');
    expect(find.textContaining('가상 지침'), findsWidgets);
    await tap(tester, find.text('정비 결과 기록'));
    expect(appRouter.routeInformationProvider.value.uri.path, '/entry');
    expect(
      appRouter
          .routeInformationProvider
          .value
          .uri
          .queryParameters['inspection'],
      'DEMO-PHOTO',
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('confirm-part-concept')),
          )
          .value,
      isFalse,
    );
    await tap(tester, find.byKey(const ValueKey('confirm-part-concept')));
    await tester.enterText(
      find.byKey(const ValueKey('정비내용')),
      '가상 공개모델 점검 후 수동 확인',
    );
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '0');
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () => s.records.any((r) => r.inspectionId == 'DEMO-PHOTO'),
    );
    final saved = s.records.firstWhere((r) => r.inspectionId == 'DEMO-PHOTO');
    expect(saved.confirmedConceptId, 'FILTER');
    expect(saved.replacementCompleted, isNull);
    expect(tester.takeException(), isNull);
  });
}
