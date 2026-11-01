import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/model_execution.dart';

const device = DeviceCapabilities(
  totalRamBytes: 400,
  availableRamBytes: 200,
  cores: 4,
  abis: ['arm64-v8a'],
  androidApi: 24,
  freeStorageBytes: 800,
  lowMemory: false,
);
// Deliberately fake units, not proposed product thresholds.
MeasuredTierRule rule({
  String platform = 'physical-android',
  String evidence = 'TEST-ONLY',
}) => MeasuredTierRule(
  tier: ModelTier.generation,
  evidenceId: evidence,
  platform: platform,
  minRamBytes: 300,
  minAvailableBytes: 100,
  minStorageBytes: 400,
  minCores: 2,
  minApi: 24,
  abis: {'arm64-v8a'},
);
const small = ModelSpec('small', ModelTask.vision, ModelTier.basic);
const large = ModelSpec('large', ModelTask.vision, ModelTier.enhanced);

class FakeWorker implements ModelWorker {
  final events = <String>[];
  String? loaded;
  bool failReset = false, failUnload = false;
  String? failModel;
  Completer<void>? inferenceGate;
  @override
  Future<void> load(String id, int threads) async {
    expect(loaded, isNull, reason: 'Never load two models concurrently');
    events.add('load:$id');
    loaded = id;
    if (id == failModel) {
      throw StateError('load failure after partial allocation');
    }
  }

  @override
  Future<Map<String, Object?>> infer(Map<String, Object?> input) async {
    events.add('infer:$loaded');
    await inferenceGate?.future;
    return {'result': loaded};
  }

  @override
  Future<void> unload() async {
    events.add('unload:$loaded');
    if (failUnload) throw StateError('close failed');
    loaded = null;
  }

  @override
  Future<void> reset() async {
    events.add('reset');
    if (failReset) throw StateError('death unconfirmed');
    loaded = null;
    // The fake emulates a killed process by releasing its blocked operation.
    inferenceGate?.complete();
    inferenceGate = null;
  }
}

void main() {
  test('RAM 단계가 높아도 LLM Android API 미충족·미명시는 로드하지 않는다', () async {
    final w = FakeWorker();
    var api = 24;
    final m = ModelExecutionManager(
      w,
      tier: () => ModelTier.generation,
      androidApi: () => api,
    );
    const model = ModelSpec(
      'test-llm',
      ModelTask.generation,
      ModelTier.generation,
      minAndroidApi: 28,
    );
    expect(
      (await m.run(ModelTask.generation, [model], {})).mode,
      'retrieval_only',
    );
    expect(w.events, isEmpty);
    api = 28;
    expect((await m.run(ModelTask.generation, [model], {})).mode, 'model');
  });
  test('실측 기준 미등록·PC 결과·근거 누락·감지 실패는 기본 단계, 사용자 상향 금지', () {
    expect(chooseTier(device, [], null), ModelTier.basic);
    expect(
      chooseTier(device, [rule(platform: 'pc-cpu')], null),
      ModelTier.basic,
    );
    expect(chooseTier(device, [rule(evidence: '')], null), ModelTier.basic);
    expect(chooseTier(null, [rule()], null), ModelTier.basic);
    expect(chooseTier(device, [], ModelTier.generation), ModelTier.basic);
    expect(chooseTier(device, [rule()], null), ModelTier.generation);
    expect(
      chooseTier(device, [rule()], ModelTier.enhanced),
      ModelTier.enhanced,
    );
    expect(
      chooseTier(device, [rule()], null, failedThisSession: true),
      ModelTier.basic,
    );
  });
  test('ABI·API·가용 RAM·저장공간·코어·저메모리 제약을 모두 검사한다', () {
    for (final d in [
      const DeviceCapabilities(
        totalRamBytes: 400,
        availableRamBytes: 99,
        cores: 4,
        abis: ['arm64-v8a'],
        androidApi: 24,
        freeStorageBytes: 800,
        lowMemory: false,
      ),
      const DeviceCapabilities(
        totalRamBytes: 400,
        availableRamBytes: 200,
        cores: 4,
        abis: ['x86_64'],
        androidApi: 24,
        freeStorageBytes: 800,
        lowMemory: false,
      ),
      const DeviceCapabilities(
        totalRamBytes: 400,
        availableRamBytes: 200,
        cores: 4,
        abis: ['arm64-v8a'],
        androidApi: 23,
        freeStorageBytes: 800,
        lowMemory: false,
      ),
      const DeviceCapabilities(
        totalRamBytes: 400,
        availableRamBytes: 200,
        cores: 4,
        abis: ['arm64-v8a'],
        androidApi: 24,
        freeStorageBytes: 399,
        lowMemory: false,
      ),
      const DeviceCapabilities(
        totalRamBytes: 400,
        availableRamBytes: 200,
        cores: 1,
        abis: ['arm64-v8a'],
        androidApi: 24,
        freeStorageBytes: 800,
        lowMemory: false,
      ),
      const DeviceCapabilities(
        totalRamBytes: 400,
        availableRamBytes: 200,
        cores: 4,
        abis: ['arm64-v8a'],
        androidApi: 24,
        freeStorageBytes: 800,
        lowMemory: true,
      ),
    ]) {
      expect(chooseTier(d, [rule()], null), ModelTier.basic);
    }
  });
  test('동시 요청을 직렬화하고 성공마다 해제한다', () async {
    final w = FakeWorker()..inferenceGate = Completer<void>();
    final m = ModelExecutionManager(w, tier: () => ModelTier.basic);
    final a = m.run(ModelTask.vision, [small], {});
    final b = m.run(ModelTask.vision, [small], {});
    await Future<void>.delayed(Duration.zero);
    expect(w.events, ['load:small', 'infer:small']);
    w.inferenceGate!.complete();
    w.inferenceGate = null;
    expect((await a).mode, 'model');
    expect((await b).mode, 'model');
    expect(w.events, [
      'load:small',
      'infer:small',
      'unload:small',
      'load:small',
      'infer:small',
      'unload:small',
    ]);
    expect(m.activeModel, isNull);
  });
  test('부분 로드 실패는 종료 확인 후 작은 모델로 대체한다', () async {
    final w = FakeWorker()..failModel = 'large';
    var tier = ModelTier.enhanced;
    final m = ModelExecutionManager(
      w,
      tier: () => tier,
      onFailure: () => tier = ModelTier.basic,
    );
    expect((await m.run(ModelTask.vision, [small, large], {})).mode, 'model');
    expect(w.events, [
      'load:large',
      'reset',
      'load:small',
      'infer:small',
      'unload:small',
    ]);
  });
  test('해제 실패·프로세스 종료 확인 실패 시 격리하고 추가 로드하지 않는다', () async {
    final w = FakeWorker()
      ..failUnload = true
      ..failReset = true;
    final m = ModelExecutionManager(w, tier: () => ModelTier.basic);
    expect(
      (await m.run(ModelTask.vision, [small], {})).reason,
      'worker_quarantined',
    );
    final count = w.events.length;
    expect((await m.run(ModelTask.vision, [small], {})).mode, 'unavailable');
    expect(w.events.length, count);
  });
  test('추론 시간 초과는 종료 확인을 거치며 이후 요청을 수행한다', () async {
    final w = FakeWorker()..inferenceGate = Completer<void>();
    final m = ModelExecutionManager(
      w,
      tier: () => ModelTier.basic,
      timeout: const Duration(milliseconds: 20),
    );
    expect((await m.run(ModelTask.vision, [small], {})).mode, 'unavailable');
    expect(w.events, contains('reset'));
    expect((await m.run(ModelTask.vision, [small], {})).mode, 'model');
  });
  test('LLM 미설치·기본 단계는 retrieval_only이며 Vision을 성공으로 위장하지 않는다', () async {
    final w = FakeWorker();
    final m = ModelExecutionManager(w, tier: () => ModelTier.basic);
    expect(
      (await m.run(ModelTask.generation, [
        const ModelSpec('llm', ModelTask.generation, ModelTier.generation),
      ], {})).mode,
      'retrieval_only',
    );
    expect((await m.run(ModelTask.vision, [], {})).mode, 'unavailable');
    expect(w.events, isEmpty);
  });
}
