import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/adaptive_runtime.dart';
import 'package:military_maintenance/data/model_execution.dart';
import 'package:military_maintenance/ui/runtime_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? saved;
  bool missing = false;
  int api = 24;
  bool optional = false, allowRun = false;
  bool pressureForwardFails = false;
  final calls = <String>[];
  setUp(() {
    saved = null;
    missing = false;
    api = 24;
    optional = false;
    allowRun = false;
    pressureForwardFails = false;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidModelWorker.channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'notifyMemoryPressure':
              if (pressureForwardFails)
                throw PlatformException(code: 'pressure_forward_failed');
              return {'action': 'forwarded'};
            case 'capabilities':
              if (missing) throw PlatformException(code: 'missing');
              return {
                'totalRamBytes': 4 * 1024 * 1024 * 1024,
                'availableRamBytes': 1024 * 1024 * 1024,
                'cores': 4,
                'abis': ['arm64-v8a'],
                'androidApi': api,
                'freeStorageBytes': 8 * 1024 * 1024 * 1024,
                'lowMemory': false,
              };
            case 'getCeiling':
              return saved;
            case 'setCeiling':
              saved = (call.arguments as Map)['tier'] as String?;
              return null;
            case 'reset':
              return null;
            case 'load':
              if (allowRun) return null;
              throw PlatformException(code: 'runtime_not_installed');
            case 'modelInfo':
              return {
                'optionalModels': optional
                    ? [
                        {
                          'installed': true,
                          'supportedAbi': true,
                          'modelId': 'qwen3-0.6b-q4_0',
                        },
                      ]
                    : [],
              };
            case 'infer':
              return {'text': 'fixture', 'ended': true};
            case 'unload':
              return null;
            default:
              throw PlatformException(code: 'unexpected');
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidModelWorker.channel, null);
  });
  test('사양 읽기·사용자 하향 저장·재시작 유지·자동 복귀', () async {
    final a = AdaptiveRuntime();
    await a.initialize();
    expect(a.device!.androidApi, 24);
    expect(a.device!.cores, 4);
    expect(a.selectedTier, ModelTier.basic);
    expect(a.generationEnabled, isFalse);
    await a.setCeiling(ModelTier.basic);
    expect(saved, 'basic');
    final b = AdaptiveRuntime();
    await b.initialize();
    expect(b.userCeiling, ModelTier.basic);
    await b.setCeiling(null);
    expect(saved, isNull);
    a.dispose();
    b.dispose();
  });
  test('선택 LLM은 API 28부터 명시 요청 한 번만 허용하고 자동 단계를 올리지 않는다', () async {
    api = 28;
    optional = true;
    allowRun = true;
    final r = AdaptiveRuntime();
    await r.initialize();
    expect(r.selectedTier, ModelTier.basic);
    expect(r.generationTrialAvailable, isTrue);
    expect(
      (await r.runOptionalGeneration({'task': 'generation'})).mode,
      'model',
    );
    expect(r.selectedTier, ModelTier.basic);
    expect(r.automaticTier, ModelTier.basic);
    await r.setCeiling(ModelTier.basic);
    expect((await r.runOptionalGeneration({})).mode, 'retrieval_only');
    r.dispose();
  });
  test('API 27에서는 설치돼 있어도 선택 LLM을 로드하지 않는다', () async {
    api = 27;
    optional = true;
    allowRun = true;
    final r = AdaptiveRuntime();
    await r.initialize();
    expect(r.generationTrialAvailable, isFalse);
    expect((await r.runOptionalGeneration({})).mode, 'retrieval_only');
    r.dispose();
  });
  test('사양 감지 실패·메모리 압박·미설치 모델은 기본/원문 모드 유지', () async {
    missing = true;
    pressureForwardFails = true;
    final r = AdaptiveRuntime();
    await r.initialize();
    expect(r.device, isNull);
    expect(r.detectionError, isNotNull);
    await r.memoryPressure();
    expect(r.failedThisSession, isTrue);
    expect(
      (await r.manager.run(ModelTask.generation, [], {})).mode,
      'retrieval_only',
    );
    r.dispose();
  });
  test('Flutter 경고를 native 정책으로 전달하며 정상 세션을 실패로 표시하지 않는다', () async {
    api = 28;
    optional = true;
    final r = AdaptiveRuntime();
    await r.initialize();
    calls.clear();
    await r.memoryPressure();
    expect(calls, contains('notifyMemoryPressure'));
    expect(calls, isNot(contains('reset')));
    expect(r.failedThisSession, isFalse);
    expect(r.generationTrialAvailable, isTrue);
    r.dispose();
  });
  test('메모리 경고 전달 실패는 모델을 해제하고 안전한 대체 세션으로 전환한다', () async {
    final r = AdaptiveRuntime();
    await r.initialize();
    calls.clear();
    pressureForwardFails = true;
    await r.memoryPressure();
    expect(r.failedThisSession, isTrue);
    expect(calls, contains('reset'));
    r.dispose();
  });
  testWidgets('설정 화면은 미검증 단계·미설치·LLM 꺼짐을 명시하고 상향 선택을 제공하지 않는다', (tester) async {
    final r = AdaptiveRuntime();
    await r.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [adaptiveRuntimeProvider.overrideWith((ref) => r)],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RuntimeSettingsPanel()),
          ),
        ),
      ),
    );
    expect(find.textContaining('RAM 4.00 GiB'), findsOneWidget);
    expect(find.textContaining('retrieval_only'), findsOneWidget);
    expect(find.textContaining('실측 전 미확정'), findsOneWidget);
    expect(find.textContaining('미등록'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('확장'), findsNothing);
    expect(find.text('생성'), findsNothing);
  });
}
