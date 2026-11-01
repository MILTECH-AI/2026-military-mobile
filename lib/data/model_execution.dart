import 'dart:async';

enum ModelTier { basic, enhanced, generation }

const maintenanceDecisionModuleName = '규칙 기반 잔여 정비거리 + 정비기록 분류';

enum ModelTask { vision, embedding, recordClassification, generation }

class DeviceCapabilities {
  const DeviceCapabilities({
    required this.totalRamBytes,
    required this.availableRamBytes,
    required this.cores,
    required this.abis,
    required this.androidApi,
    required this.freeStorageBytes,
    required this.lowMemory,
    this.cameraStatus = 'unknown',
    this.isEmulator,
  });
  final int totalRamBytes,
      availableRamBytes,
      cores,
      androidApi,
      freeStorageBytes;
  final List<String> abis;
  final bool lowMemory;
  final bool? isEmulator;
  final String cameraStatus;
  bool get cameraAvailable => cameraStatus == 'available';
  String get cameraStatusLabel => switch (cameraStatus) {
    'available' => '사용 조건 확인됨 · 실제 연결은 촬영 시 확인',
    'disabled_policy' => '보안 정책으로 사용 불가',
    'no_hardware' => '사용 가능한 카메라 없음',
    'disabled_privacy' => '기기 개인정보 보호 설정으로 차단',
    'disabled_appops' => '기기에서 카메라 사용 차단',
    'permission_required' => '촬영 권한 확인 필요',
    _ => '사용 가능 여부 확인 불가',
  };
  bool get cameraBlocked =>
      !['available', 'permission_required', 'unknown'].contains(cameraStatus);
  factory DeviceCapabilities.fromMap(Map<Object?, Object?> m) =>
      DeviceCapabilities(
        totalRamBytes: m['totalRamBytes'] as int,
        availableRamBytes: m['availableRamBytes'] as int,
        cores: m['cores'] as int,
        abis: List<String>.from(m['abis'] as List),
        androidApi: m['androidApi'] as int,
        freeStorageBytes: m['freeStorageBytes'] as int,
        lowMemory: m['lowMemory'] as bool,
        cameraStatus: m['cameraStatus'] as String? ?? 'unknown',
        isEmulator: m['isEmulator'] as bool?,
      );
}

/// Only reviewed physical-device measurements may enable an upper tier.
/// Production deliberately supplies no rules until measurements are available.
class MeasuredTierRule {
  const MeasuredTierRule({
    required this.tier,
    required this.evidenceId,
    required this.platform,
    required this.minRamBytes,
    required this.minAvailableBytes,
    required this.minStorageBytes,
    required this.minCores,
    required this.minApi,
    required this.abis,
  });
  final ModelTier tier;
  final String evidenceId, platform;
  final int minRamBytes, minAvailableBytes, minStorageBytes, minCores, minApi;
  final Set<String> abis;
  bool accepts(DeviceCapabilities d) =>
      platform == 'physical-android' &&
      evidenceId.isNotEmpty &&
      !d.lowMemory &&
      d.totalRamBytes >= minRamBytes &&
      d.availableRamBytes >= minAvailableBytes &&
      d.freeStorageBytes >= minStorageBytes &&
      d.cores >= minCores &&
      d.androidApi >= minApi &&
      d.abis.any(abis.contains);
}

ModelTier chooseTier(
  DeviceCapabilities? d,
  List<MeasuredTierRule> rules,
  ModelTier? userCeiling, {
  bool failedThisSession = false,
}) {
  var automatic = ModelTier.basic;
  if (d != null && !failedThisSession) {
    for (final r in rules) {
      if (r.accepts(d) && r.tier.index > automatic.index) automatic = r.tier;
    }
  }
  return userCeiling != null && userCeiling.index < automatic.index
      ? userCeiling
      : automatic;
}

class ModelSpec {
  const ModelSpec(this.id, this.task, this.tier, {this.minAndroidApi});
  final String id;
  final ModelTask task;
  final ModelTier tier;
  // Generation adapters must declare their actual build requirement.
  final int? minAndroidApi;
  bool supportsApi(int? api) => task != ModelTask.generation
      ? minAndroidApi == null || (api != null && api >= minAndroidApi!)
      : minAndroidApi != null && api != null && api >= minAndroidApi!;
}

abstract interface class ModelWorker {
  Future<void> load(String modelId, int threads);
  Future<Map<String, Object?>> infer(Map<String, Object?> input);
  Future<void> unload();

  /// Must complete only when the old worker cannot execute any more requests.
  /// On failure the manager quarantines the worker rather than starting a second.
  Future<void> reset();
}

class ModelRunResult {
  const ModelRunResult(this.mode, {this.output, this.reason, this.timingsMs});
  final String mode;
  final Map<String, Object?>? output;
  final String? reason;
  final Map<String, double>? timingsMs;
}

class ModelExecutionManager {
  ModelExecutionManager(
    this.worker, {
    required this.tier,
    this.androidApi,
    this.threads = 2,
    this.timeout = const Duration(seconds: 30),
    this.onFailure,
  });
  final ModelWorker worker;
  final ModelTier Function() tier;
  final int? Function()? androidApi;
  final int threads;
  // Infrastructure watchdog, not a measured service latency requirement.
  final Duration timeout;
  final void Function()? onFailure;
  Future<void> _tail = Future.value();
  bool _quarantined = false;
  String? activeModel;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  Future<bool> _reset() async {
    try {
      await worker.reset().timeout(timeout);
      activeModel = null;
      return true;
    } catch (_) {
      _quarantined = true;
      return false;
    }
  }

  Future<ModelRunResult> run(
    ModelTask task,
    List<ModelSpec> candidates,
    Map<String, Object?> input,
  ) => _serial(() async {
    if (_quarantined) return _fallback(task, 'worker_quarantined');
    final options =
        candidates
            .where(
              (m) =>
                  m.task == task &&
                  m.tier.index <= tier().index &&
                  m.supportsApi(androidApi?.call()),
            )
            .toList()
          ..sort((a, b) => b.tier.index.compareTo(a.tier.index));
    for (final m in options) {
      // Recheck after a preceding failure has lowered the session tier.
      if (m.tier.index > tier().index) continue;
      var operation = 'load';
      try {
        final timer = Stopwatch()..start();
        await worker.load(m.id, threads).timeout(timeout);
        final loadMs = timer.elapsedMicroseconds / 1000;
        activeModel = m.id;
        operation = 'infer';
        timer.reset();
        final output = await worker
            .infer(input)
            .timeout(
              task == ModelTask.generation
                  ? const Duration(seconds: 120)
                  : timeout,
            );
        final inferMs = timer.elapsedMicroseconds / 1000;
        timer.reset();
        operation = 'unload';
        await worker.unload().timeout(timeout);
        final unloadMs = timer.elapsedMicroseconds / 1000;
        activeModel = null;
        return ModelRunResult(
          'model',
          output: output,
          timingsMs: {'load': loadMs, 'infer': inferMs, 'unload': unloadMs},
        );
      } catch (failure, stack) {
        assert(() {
          // Fixed class/operation and code locations only: no input or exception message.
          print(
            'MaintenanceManager event=run_failure operation=$operation errorType=${failure.runtimeType} stack=${stack.toString().split('\n').take(3).join(' | ')}',
          );
          return true;
        }());
        onFailure?.call();
        if (!await _reset()) return _fallback(task, 'worker_quarantined');
      }
    }
    return _fallback(
      task,
      options.isEmpty ? 'no_eligible_model' : 'model_failed',
    );
  });

  ModelRunResult _fallback(ModelTask task, String reason) => ModelRunResult(
    task == ModelTask.generation ? 'retrieval_only' : 'unavailable',
    reason: reason,
  );

  Future<void> release() => _serial(() async {
    if (!_quarantined) await _reset();
  });
}
