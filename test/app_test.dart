import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/data/clock.dart';
import 'package:military_maintenance/main.dart';

Future<AppStore> mount(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final font = FontLoader('NotoSansKR')
    ..addFont(rootBundle.load('assets/fonts/NotoSansKR.ttf'));
  await font.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  final store = AppStore(clock: () => DateTime(2026, 10, 9, 12));
  await tester.runAsync(() async {
    await store.initialize(database: LocalDatabase(NativeDatabase.memory()));
  });
  expect(store.error, isNull, reason: store.initializationCause?.toString());
  appRouter.go('/');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storeProvider.overrideWith((ref) => store),
        currentTimeProvider.overrideWith((ref) => DateTime(2026, 10, 9)),
      ],
      child: const MilitaryApp(),
    ),
  );
  await tester.runAsync(
    () => precacheImage(
      const AssetImage('assets/figma/ed09d.png'),
      tester.element(find.byType(Scaffold).first),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<void> revealWidget(WidgetTester tester, Finder finder) async {
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

void main() {
  testWidgets('정비지원에서 원문 근거와 교환 기준을 등록하고 계획으로 연결한다', (tester) async {
    final store = await mount(tester, const Size(1280, 960));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appRouter.go('/support?vehicle=MOCK-RX-0001&part=brake_pad');
    await tester.pumpAndSettle();
    // Route parameters use the same standard vocabulary as image/record results.
    expect(find.text('정비 문서 근거'), findsOneWidget);
    await revealWidget(tester, find.text('근거 등록'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('근거 등록'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('증상 키워드')), '제동 소음');
    await tester.enterText(find.byKey(const ValueKey('문서명·개정판')), '테스트 정비 지침');
    await tester.enterText(find.byKey(const ValueKey('원문 위치(쪽·절)')), '3쪽 2절');
    await tester.enterText(find.byKey(const ValueKey('원문 구간')), '테스트용 원문입니다.');
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && store.supportLibrary.evidence.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(store.supportLibrary.evidence.single.part, '브레이크패드');
    expect(find.text('테스트용 원문입니다.'), findsOneWidget);
    await revealWidget(tester, find.text('주기·교환 기준 등록'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('주기·교환 기준 등록'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('권장 정비 주기(km)')), '10000');
    await tester.enterText(
      find.byKey(const ValueKey('마지막 교환 계기(km)')),
      '${store.vehicle('MOCK-RX-0001').distance}',
    );
    await tester.enterText(
      find.byKey(const ValueKey('마지막 교환일(YYYY-MM-DD)')),
      '2026-10-09',
    );
    await tester.enterText(
      find.byKey(const ValueKey('주기 근거(문서명·쪽)')),
      '테스트 지침 3쪽',
    );
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && store.supportLibrary.rules.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(store.supportLibrary.rules.single.intervalKm, 10000);
    expect(find.textContaining('잔여 10,000 km'), findsOneWidget);
    appRouter.go('/support?vehicle=MOCK-RX-0001&part=브레이크패드');
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/support_1280x960.png'),
    );
    appRouter.go('/plans?vehicle=MOCK-RX-0001');
    await tester.pumpAndSettle();
    expect(find.text('연간 정비계획'), findsNWidgets(2));
    expect(find.textContaining('MOCK-RX-0001 · 브레이크패드'), findsWidgets);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/plans_1280x960.png'),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await store.db!.close();
  });
  testWidgets('로그인 없이 현황 진입, 검색과 정비 등록을 연결한다', (tester) async {
    final store = await mount(tester, const Size(1440, 1080));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    expect(find.text('종합 현황'), findsNWidgets(2));
    expect(find.text('로그인'), findsNothing);
    appRouter.go('/vehicles');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'MOCK-RX-0001');
    await tester.pumpAndSettle();
    expect(find.text('MOCK-RX-0002'), findsNothing);
    appRouter.go('/entry?vehicle=MOCK-RX-0001');
    await tester.pumpAndSettle();
    final previousPrediction =
        store.predictions['MOCK-RX-0001']!['probability'];
    await tester.enterText(find.byKey(const ValueKey('수리부속 품명')), '테스트 냉각수 호스');
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '125000');
    await tester.enterText(
      find.byKey(const ValueKey('정비내용')),
      '호스 교체 후 누수 재점검 완료',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.runAsync(() async {
      for (
        var i = 0;
        i < 100 && store.predictions['MOCK-RX-0001']!['trigger'] != '정비 입력';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(store.records.first.part, '테스트 냉각수 호스');
    expect(
      store.predictions['MOCK-RX-0001']!['probability'],
      isNot(previousPrediction),
    );
    expect(store.predictions['MOCK-RX-0001']!['trigger'], '정비 입력');
    expect(find.textContaining('정상적으로 등록되었습니다.'), findsOneWidget);
    appRouter.go('/ai-history?vehicle=MOCK-RX-0001');
    await tester.pumpAndSettle();
    expect(find.text('정비 입력'), findsOneWidget);
    final probability =
        store.predictions['MOCK-RX-0001']!['probability'] as num;
    expect(
      find.text('${(probability * 100).toStringAsFixed(1)}%'),
      findsWidgets,
    );
    await expectLater(
      find.byType(MilitaryApp),
      matchesGoldenFile('goldens/live_ai_history_1440x1080.png'),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await store.db!.close();
  });
  testWidgets('입력 중 로컬 분류 제안을 표시하고 적용한 정비 구분을 저장한다', (tester) async {
    final store = await mount(tester, const Size(1280, 960));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appRouter.go('/entry?vehicle=MOCK-RX-0001');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('수리부속 품명')), '브레이크 호스');
    await tester.enterText(
      find.byKey(const ValueKey('정비내용')),
      '가상 점검에서 제동 압력 점검 이상 확인. 브레이크 호스 교환 후 작동 상태를 재점검함.',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('목업 분류 제안: 제동 · 고장수리'), findsOneWidget);
    await tester.ensureVisible(find.text('분류 제안 적용'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('분류 제안 적용'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('system-제동')), findsOneWidget);
    expect(find.byKey(const ValueKey('type-고장수리')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('가격(원)')), '48000');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.runAsync(() async {
      for (
        var i = 0;
        i < 100 && store.predictions['MOCK-RX-0001']!['trigger'] != '정비 입력';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(store.records.first.system, '제동');
    expect(store.records.first.maintenanceType, '고장수리');
    expect(
      store.predictions['MOCK-RX-0001']!['features']['daysSinceMaintenance'],
      0,
    );
    await tester.pumpWidget(const SizedBox());
    await store.db!.close();
  });
  testWidgets('대량 정비 기록을 나누어 조회하고 다음 페이지의 상세를 연다', (tester) async {
    final store = await mount(tester, const Size(1280, 960));
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appRouter.go('/records');
    await tester.pumpAndSettle();
    expect(tester.widget<DataTable>(find.byType(DataTable)).rows.length, 12);
    await tester.ensureVisible(find.byKey(const ValueKey('next-record-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('next-record-page')));
    await tester.pumpAndSettle();
    final firstDetail = find
        .descendant(
          of: find.byType(DataTable),
          matching: find.byType(IconButton),
        )
        .first;
    await tester.ensureVisible(firstDetail);
    await tester.pumpAndSettle();
    await tester.tap(firstDetail);
    await tester.pumpAndSettle();
    expect(
      appRouter.routeInformationProvider.value.uri.path,
      '/records/${store.records[12].id}',
    );
    await tester.pumpWidget(const SizedBox());
    await store.db!.close();
  });
  for (final size in [
    const Size(1280, 960),
    const Size(1280, 800),
    const Size(800, 1280),
    const Size(600, 800),
  ]) {
    testWidgets('태블릿 배치 ${size.width}×${size.height} 모든 업무 화면', (tester) async {
      final store = await mount(tester, size);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final route in [
        '/',
        '/vehicles',
        '/vehicles/MOCK-RX-0001',
        '/records',
        '/records/${store.records.first.id}',
        '/analysis',
        '/entry',
        '/entry?type=operation',
        '/ai-history',
        '/vision',
        '/chat',
        '/support',
        '/plans',
        '/data-tools',
        '/entry?record=${store.records.first.id}',
      ]) {
        appRouter.go(route);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: route);
        if (route == '/entry?type=operation') {
          expect(find.byKey(const ValueKey('누적 주행거리(km)')), findsOneWidget);
        }
        if (size == const Size(1280, 960) &&
            [
              '/vehicles',
              '/entry',
              '/vision',
              '/chat',
              '/data-tools',
            ].contains(route)) {
          await expectLater(
            find.byType(MilitaryApp),
            matchesGoldenFile('goldens/${route.substring(1)}_1280x960.png'),
          );
        }
      }
      appRouter.go('/');
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MilitaryApp),
        matchesGoldenFile(
          'goldens/dashboard_${size.width.toInt()}x${size.height.toInt()}.png',
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await store.db!.close();
    });
  }
}
