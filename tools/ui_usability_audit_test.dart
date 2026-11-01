// Historical pre-fix audit (2026-10-14). Current acceptance tests live in
// test/ui_usability_test.dart. These observations describe the earlier defects.
// Run explicitly with flutter test --update-goldens tools/ui_usability_audit_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/main.dart';

import '../test/app_test.dart' show mount;
import '../test/data_tools_test.dart' show tapWithIo;

final observations = <Map<String, dynamic>>[];
void record(String id, String observation, Map<String, dynamic> evidence) {
  observations.add({
    'id': id,
    'observation': observation,
    'evidence': evidence,
  });
}

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

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 300,
      scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first,
      maxScrolls: 30);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> screenshot(WidgetTester tester, String name) => expectLater(
  find.byType(MilitaryApp),
  matchesGoldenFile('../output/ui-review/$name.png'),
);

void main() {
  tearDownAll(() {
    Directory('output/ui-review').createSync(recursive: true);
    File('output/ui-review/observations.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'method': 'Simulated user tasks using Flutter widget input and rendered screenshots; no human participants or physical tablet.',
        'productCodeChanged': false,
        'observations': observations,
      }),
    );
  });

  testWidgets('첫 사용: 증상 입력 뒤 결과와 기능 상태가 첫 화면에 보이는지', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    s.supportLibrary = SupportLibrary(
      evidence: [
        MaintenanceEvidence(
          id: 'DOC',
          model: v.model,
          part: '배터리',
          symptoms: '시동 불량',
          title: '시험 근거',
          location: '1쪽',
          text: '시동 불량 점검 근거',
        ),
      ],
    );
    appRouter.go('/support?vehicle=${v.id}');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('support-query')),
      '시동이 걸리지 않아요',
    );
    await tester.pumpAndSettle();
    final resultCount = s.searchEvidence(v.id, '', '시동이 걸리지 않아요').length;
    final keywordCount = s.searchEvidence(v.id, '', '시동').length;
    final limitation = find.textContaining('로컬 키워드 검색입니다.');
    final rect = limitation.evaluate().isEmpty ? null : tester.getRect(limitation);
    final inViewport = rect?.overlaps(const Rect.fromLTWH(216, 72, 1064, 728)) ?? false;
    expect(resultCount, 0);
    expect(keywordCount, 1);
    record('U1', '일상적인 증상 문장은 근거를 못 찾고 짧은 키워드만 찾음', {
      'sentenceResults': resultCount,
      'keywordResults': keywordCount,
      'limitationInitiallyVisible': inViewport,
      'limitationTop': rect?.top,
      'height': 800,
      'query': '시동이 걸리지 않아요',
    });
    await screenshot(tester, '01-search-first-viewport');
    await reveal(tester, limitation);
    await screenshot(tester, '02-search-empty-results');
  });

  testWidgets('업무 연결: 정비지원에서 지정한 부품이 촬영으로 이어지는지', (tester) async {
    final s = await setup(tester);
    appRouter.go('/support?vehicle=${s.vehicles.first.id}&part=브레이크패드');
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('현장 촬영·부품 지정'));
    await tapVisible(tester, find.text('시작하기'));
    final selected = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((chip) => chip.selected)
        .map((chip) => (chip.label as Padding).child as Text)
        .map((t) => t.data)
        .toList();
    expect(selected, ['외관']);
    record('U2', '차량은 유지되지만 부품 선택이 사라지고 외관으로 초기화됨', {
      'requestedPart': '브레이크패드',
      'selectedAreas': selected,
      'route': appRouter.routeInformationProvider.value.uri.toString(),
    });
    await screenshot(tester, '03-inspection-context');
  });

  testWidgets('입력 복구: 천 단위 숫자 입력과 날짜·숫자 키보드 안내', (tester) async {
    final s = await setup(tester, size: const Size(800, 1280));
    final v = s.vehicles.first;
    appRouter.go('/support?vehicle=${v.id}&part=엔진오일');
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('주기·교환 기준 등록'));
    final numeric = find.byKey(const ValueKey('권장 정비 주기(km)'));
    final input = tester.widget<TextField>(numeric);
    await tester.enterText(numeric, '10,000');
    await tester.enterText(
      find.byKey(const ValueKey('마지막 교환 계기(km)')),
      '${v.distance}',
    );
    await tester.enterText(
      find.byKey(const ValueKey('마지막 교환일(YYYY-MM-DD)')),
      '2026-10-09',
    );
    await tester.enterText(
      find.byKey(const ValueKey('주기 근거(문서명·쪽)')),
      '시험 지침 1쪽',
    );
    await tapVisible(tester, find.widgetWithText(FilledButton, '저장'));
    expect(find.text('입력 형식·필수값·숫자 범위를 확인해 주세요.'), findsOneWidget);
    expect(s.supportLibrary.rules, isEmpty);
    record('U3', '10,000 입력 시 저장 실패하며 문제 필드를 특정하지 않는 오류만 표시', {
      'input': '10,000',
      'keyboardType': input.keyboardType.toString(),
      'numericFormatters': input.inputFormatters?.length ?? 0,
      'datePickerCount': find.byType(DatePickerDialog).evaluate().length,
    });
    await screenshot(tester, '04-rule-input-error');
  });

  testWidgets('실수 방지: 등록 근거 삭제 시 확인 또는 되돌리기가 있는지', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    await tester.runAsync(
      () => s.saveSupportLibrary(
        SupportLibrary(
          evidence: [
            MaintenanceEvidence(
              id: 'DOC-DELETE',
              model: v.model,
              part: '배터리',
              symptoms: '시동',
              title: '삭제 시험 원문',
              location: '1쪽',
              text: '다시 입력해야 하는 근거',
            ),
          ],
        ),
      ),
    );
    appRouter.go('/support?vehicle=${v.id}&part=배터리');
    await tester.pumpAndSettle();
    final delete = find.text('등록 근거 삭제');
    await reveal(tester, delete);
    await tapWithIo(
      tester,
      delete,
      completed: () => s.supportLibrary.evidence.isEmpty,
    );
    expect(s.supportLibrary.evidence, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('실행 취소'), findsNothing);
    record('U4', '삭제를 한 번 누르면 확인·실행 취소 없이 저장된 원문 근거가 즉시 삭제됨', {
      'remainingEvidence': s.supportLibrary.evidence.length,
      'confirmation': false,
      'undo': false,
    });
    await screenshot(tester, '05-deleted-evidence');
  });

  testWidgets('계획 첫 사용: 주기 등록 버튼이 등록 양식으로 바로 이동하는지', (tester) async {
    final s = await setup(tester);
    appRouter.go('/plans?vehicle=${s.vehicles.first.id}');
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('AI 정비지원에서 주기 등록'));
    expect(find.byType(AlertDialog), findsNothing);
    final formField = find.byKey(const ValueKey('권장 정비 주기(km)'));
    expect(formField, findsNothing);
    record('U5', '주기 등록 버튼은 정비지원 첫 화면으로 이동하며 등록 양식은 한 번 더 찾아 열어야 함', {
      'landedRoute': appRouter.routeInformationProvider.value.uri.toString(),
      'registrationFormOpen': false,
    });
    await screenshot(tester, '06-plan-registration-detour');
  });

  testWidgets('검토 후 복귀: 근거에서 정비 상세 확인 후 검색 조건이 유지되는지', (tester) async {
    final s = await setup(tester);
    final v = s.vehicles.first;
    appRouter.go('/support?vehicle=${v.id}&part=배터리');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('support-query')), '시동');
    await tester.pumpAndSettle();
    // Follow a related record when available, then return through the vehicle link.
      await tapVisible(tester, find.text('차량 상세'));
    await tapVisible(tester, find.widgetWithText(OutlinedButton, 'AI 정비지원'));
    final query = tester
        .widget<TextField>(find.byKey(const ValueKey('support-query')))
        .controller!
        .text;
    expect(query, isEmpty);
    final partField = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).last,
    );
    expect(partField.initialValue, '');
    record('U6', '차량 상세를 확인하고 정비지원으로 복귀하면 부품과 증상 입력이 사라짐', {
      'previousPart': '배터리',
      'previousQuery': '시동',
      'returnedPart': partField.initialValue,
      'returnedQuery': query,
    });
  });

  for (final route in ['/support', '/plans', '/vision']) {
    testWidgets('접근성: 600×800 글자 1.6배 $route', (tester) async {
      await setup(tester, size: const Size(600, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      appRouter.go(route);
      await tester.pumpAndSettle();
      final errors = <String>[];
      Object? error;
      while ((error = tester.takeException()) != null) {
        errors.add(error.toString());
      }
      record('A-${route.substring(1)}', '좁은 화면·확대 글자 배치 검사', {
        'size': '600x800',
        'textScale': 1.6,
        'errors': errors,
      });
      await screenshot(tester, '07-large-text-${route.substring(1)}');
    });
  }
}
