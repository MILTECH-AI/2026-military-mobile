import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';

import 'ui_usability_test.dart' show setup, tap, reveal;
import 'data_tools_test.dart' show tapWithIo;

void main() {
  testWidgets('실사용 준비부터 점검·교환 완료·다음 계획·사진 조회까지 연결한다', (tester) async {
    final s = await setup(tester, size: const Size(1280, 960));
    await tap(tester, find.text('실사용 준비·차량 등록'));
    await tap(tester, find.widgetWithText(FilledButton, '차량 등록'));
    for (final e in {
      '차량번호': 'FLOW-REAL-1',
      '차종': '실사용 흐름 시험차',
      '출고연도': '2020',
      '누적 주행거리(km)': '20,000',
      '누적 주행시간(H)': '500',
      '누적 유류 사용량(L)': '1,000',
    }.entries) {
      await tester.enterText(
        find.byKey(ValueKey('register-${e.key}')),
        e.value,
      );
    }
    await tapWithIo(
      tester,
      find.widgetWithText(FilledButton, '등록'),
      completed: () => s.registeredVehicles.isNotEmpty,
    );
    expect(s.registeredVehicles.single.id, 'FLOW-REAL-1');
    await tap(tester, find.text('정비 근거 등록'));
    for (final e in {
      '표준부품명': '엔진오일',
      '증상 키워드': '교환',
      '문서명·개정판': '가상 시험 지침',
      '원문 위치(쪽·절)': '1쪽',
      '원문 구간': '사용 흐름 시험용 원문입니다.',
    }.entries) {
      await tester.enterText(find.byKey(ValueKey(e.key)), e.value);
    }
    await tapWithIo(
      tester,
      find.widgetWithText(FilledButton, '저장'),
      completed: () => s.supportLibrary.evidence.isNotEmpty,
    );
    await tap(tester, find.widgetWithText(OutlinedButton, '정비 주기 등록'));
    for (final e in {
      '표준부품명': '엔진오일',
      '권장 정비 주기(km)': '5,000',
      '마지막 교환 계기(km)': '13,000',
      '마지막 교환일(YYYY-MM-DD)': '2026-10-01',
      '주기 근거(문서명·쪽)': '가상 시험 지침 1쪽',
    }.entries) {
      await tester.enterText(find.byKey(ValueKey(e.key)), e.value);
    }
    await tapWithIo(
      tester,
      find.widgetWithText(FilledButton, '저장'),
      completed: () => s.supportLibrary.rules.isNotEmpty,
    );
    expect(s.serviceDistance(s.supportLibrary.rules.single).remainingKm, 0);
    // Replace only camera acquisition with an explicit fixture. Subsequent
    // navigation, carry-over, completion and plan inspection use real widgets.
    await tester.runAsync(
      () => s.saveInspection(
        Inspection(
          id: 'FLOW-PHOTO',
          vehicleId: 'FLOW-REAL-1',
          area: '엔진오일',
          mode: '부품 촬영',
          created: '2026-10-09T10:00:00',
          imagePath: File('assets/figma/ed09d.png').absolute.path,
          note: '가상 점검에서 교환 필요 확인',
        ),
      ),
    );
    await tap(tester, find.text('차량 정비지원 시작'));
    await tap(tester, find.widgetWithText(ListTile, '엔진오일 · 2026-10-09'));
    await tap(tester, find.text('정비 기록 등록'));
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('수리부속 품명')))
          .controller!
          .text,
      '엔진오일',
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('정비내용')))
          .controller!
          .text,
      '가상 점검에서 교환 필요 확인',
    );
    expect(find.textContaining('점검 기록 연결'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('replacement-completed')));
    await tap(tester, find.text('교환 완료').last);
    await tester.enterText(
      find.byKey(const ValueKey('교환 당시 누적 주행거리(km)')),
      '20,000',
    );
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '50,000');
    await tester.enterText(
      find.byKey(const ValueKey('정비내용')),
      '가상 점검 결과 확인 후 엔진오일 교환 완료',
    );
    await tap(tester, find.byKey(const ValueKey('system-냉각')));
    await tap(tester, find.text('엔진/연료').last);
    await reveal(tester, find.text('저장'));
    await tapWithIo(
      tester,
      find.text('저장'),
      completed: () => s.history('FLOW-REAL-1').isNotEmpty,
    );
    final record = s.history('FLOW-REAL-1').single;
    expect(record.inspectionId, 'FLOW-PHOTO');
    expect(record.replacementCompleted, isTrue);
    expect(record.odometerKm, 20000);
    expect(find.textContaining('다음 정비까지 5,000 km'), findsOneWidget);
    expect(find.text('저장'), findsNothing);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/completion_success_1280x960.png'),
    );
    await tap(tester, find.text('다음 정비계획 확인'));
    expect(find.textContaining('교환 여부 미확인 기록이 있습니다.'), findsNothing);
    expect(s.serviceDistance(s.supportLibrary.rules.single).remainingKm, 5000);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/completion_plan_1280x960.png'),
    );
    appRouter.go('/records/${record.id}');
    await tester.pumpAndSettle();
    await tap(tester, find.text('연결된 점검·사진 보기'));
    expect(
      appRouter.routeInformationProvider.value.uri.queryParameters['session'],
      'FLOW-PHOTO',
    );
    expect(find.text('가상 점검에서 교환 필요 확인'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(600, 800), const Size(800, 1280)]) {
    testWidgets('실사용 준비·차량 등록 배치 ${size.width}×${size.height}', (tester) async {
      await setup(tester, size: size);
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      appRouter.go('/setup');
      await tester.pumpAndSettle();
      await tap(tester, find.widgetWithText(FilledButton, '차량 등록'));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MilitaryApp),
        matchesGoldenFile(
          'goldens/vehicle_registration_${size.width.toInt()}x${size.height.toInt()}.png',
        ),
      );
    });
  }
}
