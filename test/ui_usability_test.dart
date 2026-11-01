import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';

import 'app_test.dart' show mount;
import 'data_tools_test.dart' show tapWithIo;

Future<AppStore> setup(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
}) async {
  final s = await mount(tester, size);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await s.db!.close();
  });
  return s;
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      maxScrolls: 40,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> dismissNotifications(WidgetTester tester) async {
  // SnackBarAction's animation completion is scheduled in tapWithIo's real
  // async zone. Flush it while the messenger is still mounted.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  final messenger = tester.state<ScaffoldMessengerState>(
    find.byType(ScaffoldMessenger).first,
  );
  messenger.clearSnackBars();
  messenger.removeCurrentSnackBar();
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
}

MaintenanceEvidence doc(Vehicle v, String id) => MaintenanceEvidence(
  id: id,
  model: v.model,
  part: '배터리',
  symptoms: '시동 불량',
  title: '시험 정비 근거 $id',
  location: '1쪽',
  text: '시동 불량에 관한 시험용 원문입니다.',
);

void main() {
  testWidgets('일상 문장 검색 결과와 지원 상태를 바로 표시하고 원문을 연다', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    s.supportLibrary = SupportLibrary(evidence: [doc(v, 'DOC')]);
    appRouter.go('/support?vehicle=${v.id}');
    await tester.pumpAndSettle();
    expect(find.textContaining('자동 답변 미연결'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('support-query')),
      '시동이 걸리지 않아요',
    );
    await tester.pumpAndSettle();
    expect(s.searchEvidence(v.id, '', '시동이 걸리지 않아요').single.id, 'DOC');
    final count = find.byKey(const ValueKey('support-result-count'));
    expect(
      find.text(
        '문서 근거 1건 · 관련 이력 ${s.relatedMaintenance(v.id, '', '시동이 걸리지 않아요').length}건',
      ),
      findsOneWidget,
    );
    expect(
      tester.getRect(count).overlaps(const Rect.fromLTWH(216, 72, 1064, 728)),
      isTrue,
    );
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/usability_search_1280x800.png'),
    );
    await tap(tester, find.widgetWithText(ListTile, '시험 정비 근거 DOC · 1쪽').first);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SelectableText),
      ),
      findsOneWidget,
    );
    await tap(tester, find.text('닫기'));
    await tap(tester, find.byTooltip('검색어 지우기'));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('support-query')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('정비지원에서 선택한 부품과 차량을 촬영 대상으로 유지한다', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    appRouter.go('/support?vehicle=${v.id}&part=브레이크패드');
    await tester.pumpAndSettle();
    await tap(tester, find.text('현장 촬영·부품 지정'));
    await tap(tester, find.text('시작하기'));
    final selected = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((chip) => chip.selected)
        .single;
    expect(((selected.label as Padding).child as Text).data, '브레이크패드');
    expect(
      appRouter.routeInformationProvider.value.uri.queryParameters['vehicle'],
      v.id,
    );
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/usability_inspection_1280x800.png'),
    );
  });

  testWidgets('쉼표 숫자 저장·숫자 키보드·교환 계기 오류·달력 선택을 지원한다', (tester) async {
    final s = await setup(tester, size: const Size(800, 1280));
    final v = s.vehicles.first;
    appRouter.go('/plans?vehicle=${v.id}');
    await tester.pumpAndSettle();
    await tap(tester, find.text('정비 주기 등록'));
    expect(appRouter.routeInformationProvider.value.uri.path, '/plans');
    expect(find.byType(AlertDialog), findsOneWidget);
    final numeric = find.byKey(const ValueKey('권장 정비 주기(km)'));
    final input = tester.widget<TextField>(
      find.descendant(of: numeric, matching: find.byType(TextField)),
    );
    expect(input.keyboardType, TextInputType.number);
    await tester.enterText(find.byKey(const ValueKey('표준부품명')), '엔진오일');
    await tester.enterText(numeric, '-100');
    await tester.pumpAndSettle();
    expect(find.text('숫자를 입력해 주세요. 예: 10,000'), findsOneWidget);
    await tester.enterText(numeric, '10,000');
    await tester.enterText(
      find.byKey(const ValueKey('마지막 교환 계기(km)')),
      '${v.distance + 1}',
    );
    await tester.enterText(
      find.byKey(const ValueKey('주기 근거(문서명·쪽)')),
      '시험 지침 1쪽',
    );
    await tap(tester, find.byTooltip('교환일 선택'));
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tap(tester, find.text('확인'));
    await tap(tester, find.widgetWithText(FilledButton, '저장'));
    expect(find.textContaining('교환 계기는 현재 누적'), findsOneWidget);
    expect(s.supportLibrary.rules, isEmpty);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/usability_validation_800x1280.png'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('마지막 교환 계기(km)')),
      '${v.distance}',
    );
    final save = find.widgetWithText(FilledButton, '저장');
    await reveal(tester, save);
    await tapWithIo(
      tester,
      save,
      completed: () => s.supportLibrary.rules.isNotEmpty,
    );
    expect(s.supportLibrary.rules.single.intervalKm, 10000);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('근거 삭제를 취소하거나 삭제 후 되돌려도 새 자료가 보존된다', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    await tester.runAsync(
      () =>
          s.saveSupportLibrary(SupportLibrary(evidence: [doc(v, 'ORIGINAL')])),
    );
    appRouter.go('/support?vehicle=${v.id}&part=배터리');
    await tester.pumpAndSettle();
    await tap(tester, find.text('등록 근거 삭제'));
    expect(find.text('삭제 확인'), findsOneWidget);
    expect(s.supportLibrary.evidence.length, 1);
    await tap(tester, find.text('취소'));
    expect(s.supportLibrary.evidence.length, 1);
    await tap(tester, find.text('등록 근거 삭제'));
    await tapWithIo(
      tester,
      find.widgetWithText(FilledButton, '삭제'),
      completed: () => s.supportLibrary.evidence.isEmpty,
    );
    expect(find.text('실행 취소'), findsOneWidget);
    // Undo merges with the latest state, instead of restoring an old full snapshot.
    await tester.runAsync(
      () => s.updateSupportLibrary(
        (current) => SupportLibrary(
          evidence: [...current.evidence, doc(v, 'NEW')],
          rules: current.rules,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapWithIo(
      tester,
      find.text('실행 취소'),
      completed: () => s.supportLibrary.evidence.length == 2,
    );
    expect(
      s.supportLibrary.evidence.map((e) => e.id),
      containsAll(['ORIGINAL', 'NEW']),
    );
    await dismissNotifications(tester);
  });

  testWidgets('정비 주기 삭제와 실행 취소 후 거리 계산을 복원한다', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    final r = MaintenanceRule(
      id: 'UNDO-RULE',
      vehicleId: v.id,
      part: '엔진오일',
      intervalKm: 10000,
      baselineKm: v.distance,
      baselineDate: '2026-10-09',
      source: '시험 지침',
    );
    await tester.runAsync(
      () => s.saveSupportLibrary(SupportLibrary(rules: [r])),
    );
    appRouter.go('/support?vehicle=${v.id}&part=엔진오일');
    await tester.pumpAndSettle();
    await tap(tester, find.text('주기 삭제'));
    await tapWithIo(
      tester,
      find.widgetWithText(FilledButton, '삭제'),
      completed: () => s.supportLibrary.rules.isEmpty,
    );
    await tapWithIo(
      tester,
      find.text('실행 취소'),
      completed: () => s.supportLibrary.rules.isNotEmpty,
    );
    expect(s.serviceDistance(s.supportLibrary.rules.single).remainingKm, 10000);
    await dismissNotifications(tester);
  });

  testWidgets('차량 상세 왕복 뒤 증상·부품·스크롤 위치를 보존한다', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    appRouter.go('/support?vehicle=${v.id}&part=배터리');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('support-query')),
      '시동이 걸리지 않아요',
    );
    await tester.pumpAndSettle();
    await tap(tester, find.text('차량 상세'));
    await tap(tester, find.widgetWithText(OutlinedButton, 'AI 정비지원'));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('support-query')))
          .controller!
          .text,
      '시동이 걸리지 않아요',
    );
    final field = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).last,
    );
    expect(field.initialValue, '배터리');
    await reveal(tester, find.text('주기·교환 기준 등록'));
    final savedOffset = s.supportDrafts[v.id]!.offset;
    expect(savedOffset, greaterThan(0));
    appRouter.go('/vehicles/${v.id}');
    await tester.pumpAndSettle();
    await tap(tester, find.widgetWithText(OutlinedButton, 'AI 정비지원'));
    final list = tester.widget<ListView>(find.byType(ListView).last);
    expect(list.controller!.offset, closeTo(savedOffset, 2));
  });

  testWidgets('전체 차량 계획에서 등록 차량을 명시적으로 선택한다', (tester) async {
    final s = await setup(tester);
    appRouter.go('/plans');
    await tester.pumpAndSettle();
    await tap(tester, find.text('정비 주기 등록'));
    expect(find.text('정비 주기를 등록할 차량'), findsOneWidget);
    final v = s.vehicles.first;
    await tap(
      tester,
      find.widgetWithText(SimpleDialogOption, '${v.id} · ${v.model}').first,
    );
    expect(find.text('${v.id} 정비 주기 등록'), findsOneWidget);
  });

  for (final route in ['/support', '/plans', '/vision']) {
    testWidgets('600×800 글자 1.6배 입력·대화상자 $route', (tester) async {
      await setup(tester, size: const Size(600, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      appRouter.go(route);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (route == '/plans') {
        await tap(tester, find.text('정비 주기 등록'));
        expect(tester.takeException(), isNull);
        await tap(tester, find.byType(SimpleDialogOption).first);
        expect(tester.takeException(), isNull);
      }
      await expectLater(
        find.byType(MilitaryApp),
        matchesGoldenFile(
          'goldens/usability_${route.substring(1)}_large_text.png',
        ),
      );
    });
  }
}
