import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'model_execution.dart';

class AndroidModelWorker implements ModelWorker {
  static const channel = MethodChannel('maintenance/model_runtime');
  @override
  Future<void> load(String modelId, int threads) async {
    await channel.invokeMethod<Object?>('load', {
      'modelId': modelId,
      'threads': threads,
    });
  }

  @override
  Future<Map<String, Object?>> infer(Map<String, Object?> input) async =>
      Map<String, Object?>.from(
        await channel.invokeMapMethod<String, Object?>('infer', input) ?? {},
      );
  @override
  Future<void> unload() async {
    await channel.invokeMethod<Object?>('unload');
  }

  @override
  Future<void> reset() async {
    await channel.invokeMethod<Object?>('reset');
  }
}

final adaptiveRuntimeProvider = ChangeNotifierProvider<AdaptiveRuntime>(
  (ref) => AdaptiveRuntime(),
);

class AdaptiveRuntime extends ChangeNotifier {
  AdaptiveRuntime({ModelWorker? worker, this.threads = 2})
    : _worker = worker ?? AndroidModelWorker();
  final ModelWorker _worker;
  final int threads;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  DeviceCapabilities? device;
  ModelTier? userCeiling;
  String? detectionError, settingsError;
  bool initialized = false, failedThisSession = false;
  bool cameraOpenFailed = false;
  bool _generationTrial = false;
  bool get generationTrialAvailable =>
      !failedThisSession &&
      device != null &&
      !device!.lowMemory &&
      (userCeiling == null || userCeiling == ModelTier.generation) &&
      installedModels.any(
        (m) =>
            m.task == ModelTask.generation && m.supportsApi(device?.androidApi),
      );
  bool get cameraBlocked =>
      cameraOpenFailed || (device?.cameraBlocked ?? false);
  void cameraFailed() {
    cameraOpenFailed = true;
    notifyListeners();
  }

  void cameraOpened() {
    cameraOpenFailed = false;
    notifyListeners();
  }

  Future<void>? _initializing;
  // No invented RAM thresholds, and no automatic upgrade based on PC results.
  final List<MeasuredTierRule> measuredRules = const [];
  List<MeasuredTierRule> get applicableRules => measuredRules
      .where(
        (r) =>
            r.tier != ModelTier.generation ||
            installedModels.any(
              (m) =>
                  m.task == ModelTask.generation &&
                  m.supportsApi(device?.androidApi),
            ),
      )
      .toList();
  List<ModelSpec> installedModels = const [];
  Map<String, Object?> modelInfo = const {};
  Future<void> refreshModels() async {
    try {
      modelInfo =
          await AndroidModelWorker.channel.invokeMapMethod<String, Object?>(
            'modelInfo',
          ) ??
          {};
      installedModels =
          modelInfo['installed'] == true &&
              modelInfo['modelId'] == 'distiluse-int8-v1'
          ? [
              const ModelSpec(
                'distiluse-int8-v1',
                ModelTask.embedding,
                ModelTier.basic,
                minAndroidApi: 24,
              ),
            ]
          : [];
      final optional = modelInfo['optionalModels'] as List? ?? const [];
      final pilot = modelInfo['systemPilot'] as Map?;
      if (pilot?['installed'] == true &&
          pilot?['modelId'] == 'maintenance-system-pilot-v1') {
        installedModels.add(
          const ModelSpec(
            'maintenance-system-pilot-v1',
            ModelTask.recordClassification,
            ModelTier.basic,
            minAndroidApi: 24,
          ),
        );
      }
      for (final item in optional.cast<Map>()) {
        if (item['installed'] == true &&
            item['modelId'] == 'ssd-mobilenet-int8-public-v1') {
          installedModels.add(
            const ModelSpec(
              'ssd-mobilenet-int8-public-v1',
              ModelTask.vision,
              ModelTier.basic,
              minAndroidApi: 24,
            ),
          );
        }
        if (item['installed'] == true &&
            item['supportedAbi'] == true &&
            item['modelId'] == 'qwen3-0.6b-q4_0') {
          installedModels.add(
            const ModelSpec(
              'qwen3-0.6b-q4_0',
              ModelTask.generation,
              ModelTier.generation,
              minAndroidApi: 28,
            ),
          );
        }
      }
    } catch (_) {
      modelInfo = {};
      installedModels = [];
    }
    notifyListeners();
  }

  Future<void> installEmbedding(String path) async {
    await manager.release();
    await AndroidModelWorker.channel.invokeMethod<Object?>('installEmbedding', {
      'path': path,
    });
    await refreshModels();
  }

  Future<void> installLlm(String path) async {
    await manager.release();
    await AndroidModelWorker.channel.invokeMethod<Object?>('installLlm', {
      'path': path,
    });
    await refreshModels();
  }

  Future<void> installVision(String path) async {
    await manager.release();
    await AndroidModelWorker.channel.invokeMethod<Object?>('installVision', {
      'path': path,
    });
    await refreshModels();
  }

  Future<void> installSystemPilot(String path) async {
    await manager.release();
    await AndroidModelWorker.channel.invokeMethod<Object?>(
      'installSystemPilot',
      {'path': path},
    );
    await refreshModels();
  }

  /// Explicit one-request experiment, never an automatic RAM-based promotion.
  Future<ModelRunResult> runOptionalGeneration(
    Map<String, Object?> input,
  ) async {
    await initialize();
    await refreshDevice();
    if (_generationTrial || !generationTrialAvailable) {
      return const ModelRunResult(
        'retrieval_only',
        reason: 'optional_generation_unavailable',
      );
    }
    _generationTrial = true;
    notifyListeners();
    try {
      return await run(ModelTask.generation, input);
    } finally {
      _generationTrial = false;
      notifyListeners();
    }
  }

  late final manager = ModelExecutionManager(
    _worker,
    threads: threads,
    tier: () => selectedTier,
    androidApi: () => device?.androidApi,
    onFailure: () {
      failedThisSession = true;
      notifyListeners();
    },
  );
  ModelTier get selectedTier => _generationTrial && generationTrialAvailable
      ? ModelTier.generation
      : chooseTier(
          device,
          applicableRules,
          userCeiling,
          failedThisSession: failedThisSession,
        );
  ModelTier get automaticTier => chooseTier(
    device,
    applicableRules,
    null,
    failedThisSession: failedThisSession,
  );
  Future<void> memoryPressure() async {
    try {
      // Flutter omits the trim level; the worker applies the observed-RAM policy.
      await AndroidModelWorker.channel.invokeMethod<Object?>(
        'notifyMemoryPressure',
      );
      await refreshDevice();
    } catch (_) {
      failedThisSession = true;
      notifyListeners();
      await manager.release();
    }
  }

  bool get generationEnabled =>
      selectedTier == ModelTier.generation &&
      installedModels.any(
        (m) =>
            m.task == ModelTask.generation && m.supportsApi(device?.androidApi),
      );

  Future<ModelRunResult> run(ModelTask task, Map<String, Object?> input) async {
    await initialize();
    await refreshDevice();
    if (task == ModelTask.vision &&
        (cameraBlocked || device?.cameraAvailable != true)) {
      return const ModelRunResult('unavailable', reason: 'camera_unavailable');
    }
    return manager.run(
      task,
      installedModels.where((m) => m.supportsApi(device?.androidApi)).toList(),
      input,
    );
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    await refreshDevice();
    await refreshModels();
    try {
      final value = await AndroidModelWorker.channel.invokeMethod<String>(
        'getCeiling',
      );
      userCeiling = ModelTier.values.where((t) => t.name == value).firstOrNull;
    } catch (_) {
      settingsError = '모델 단계 설정을 읽지 못했습니다.';
    }
    initialized = true;
    notifyListeners();
  }

  Future<void> refreshDevice() async {
    try {
      final data = await AndroidModelWorker.channel
          .invokeMapMethod<Object?, Object?>('capabilities');
      device = DeviceCapabilities.fromMap(data!);
      detectionError = null;
    } catch (_) {
      device = null;
      detectionError = '기기 사양을 확인하지 못했습니다. 기본 단계를 유지합니다.';
    }
    notifyListeners();
  }

  Future<void> setCeiling(ModelTier? value) async {
    try {
      await manager.release();
      await AndroidModelWorker.channel.invokeMethod<Object?>('setCeiling', {
        'tier': value?.name,
      });
      userCeiling = value;
      settingsError = null;
    } catch (_) {
      settingsError = '모델 단계 설정을 저장하지 못했습니다.';
    }
    notifyListeners();
  }
}
