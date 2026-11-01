import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/adaptive_runtime.dart';
import 'package:military_maintenance/data/model_execution.dart';
import 'package:military_maintenance/data/system_pilot.dart';
import 'package:military_maintenance/ui/system_pilot_panel.dart';

import 'data_tools_test.dart' show tapWithIo;

class PilotRuntime extends AdaptiveRuntime {
  PilotRuntime(String path) {
    modelInfo = {
      'systemPilot': {
        'installed': true,
        'metadataPath': path,
        'modelSha256': 'FIXTURE',
      },
    };
  }
  int calls = 0;
  bool bad = false;
  @override
  Future<void> initialize() async {}
  @override
  Future<ModelRunResult> run(ModelTask task, Map<String, Object?> input) async {
    expect(task, ModelTask.recordClassification);
    expect((input['features'] as List).length, 4096);
    calls++;
    final labels = maintenanceSystems.toList();
    return ModelRunResult(
      'model',
      output: {
        'modelId': systemPilotId,
        'modelSha256': bad ? 'OTHER' : 'FIXTURE',
        'labels': labels,
        'scores': [1.0, ...List.filled(8, 0.0)],
        'sourceStatus': 'authorship_unconfirmed',
        'labelStatus': 'single_ai_draft_not_human_reviewed',
        'use': 'suggestion_only',
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late PilotRuntime runtime;
  bool providerOwnsRuntime = false;
  setUp(() async {
    providerOwnsRuntime = false;
    dir = await Directory.systemTemp.createTemp('system-pilot-fixture-');
    final f = File('${dir.path}/model.json');
    await f.writeAsString(
      jsonEncode({
        'version': 1,
        'modelId': systemPilotId,
        'featureConfig': systemFeatureConfig,
        'dimension': 4096,
        'labels': maintenanceSystems.toList(),
        'sourceStatus': 'authorship_unconfirmed',
        'labelStatus': 'single_ai_draft_not_human_reviewed',
        'use': 'suggestion_only',
        'seenFeatureIds': List.generate(4096, (i) => i),
      }),
    );
    runtime = PilotRuntime(f.path);
  });
  tearDown(() async {
    if (!providerOwnsRuntime) runtime.dispose();
    await dir.delete(recursive: true);
  });
  test('식별자·숫자를 제거하고 결정적인 문자 특징을 만들며 긴 입력을 자르지 않는다', () async {
    expect(
      normalizeSystemText('FAKE-001 필터 123 점검', identifiers: ['FAKE-001']),
      '필터 점검',
    );
    expect(
      systemFeatureIds(normalizeSystemText('필터 점검')),
      systemFeatureIds(normalizeSystemText('필터 99 점검')),
    );
    expect(
      (await SystemPilot.suggest(runtime, '0' * 2001)).reason,
      'input_too_long',
    );
    expect(
      (await SystemPilot.suggest(runtime, '1234')).reason,
      'empty_features',
    );
    expect(runtime.calls, 0);
  });
  test('파일럿은 제안으로만 반환하고 모델 해시가 다르면 사용하지 않는다', () async {
    final p = await SystemPilot.suggest(runtime, '가상 엔진 점검');
    expect(p.mode, 'suggestion_only');
    expect(p.labels.first, '엔진/연료');
    runtime.bad = true;
    expect(
      (await SystemPilot.suggest(runtime, '가상 엔진 점검')).mode,
      'unavailable',
    );
  });
  testWidgets('계통 제안은 표시만 하고 사용자 선택 전에는 필드를 바꾸지 않는다', (tester) async {
    providerOwnsRuntime = true;
    final applied = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [adaptiveRuntimeProvider.overrideWith((ref) => runtime)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SystemPilotPanel(
                text: '가상 엔진 점검',
                identifiers: const [],
                onApply: applied.add,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('단일 AI 라벨 초안'), findsOneWidget);
    await tapWithIo(
      tester,
      find.byKey(const ValueKey('system-pilot-run')),
      completed: () => find
          .byKey(const ValueKey('system-pilot-apply-엔진/연료'))
          .evaluate()
          .isNotEmpty,
    );
    expect(applied, isEmpty);
    await tester.tap(find.byKey(const ValueKey('system-pilot-apply-엔진/연료')));
    await tester.pumpAndSettle();
    expect(applied, ['엔진/연료']);
  });
}
