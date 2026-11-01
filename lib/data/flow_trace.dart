import 'dart:async';

import 'adaptive_runtime.dart';
import 'model_execution.dart';

class FlowTrace {
  final watch = Stopwatch();
  final stages = <Map<String, Object?>>[];
  final modelEvents = <Map<String, Object?>>[];
  String phase = 'setup';
  double controlMs = 0;
  double get elapsedMs => watch.elapsedMicroseconds / 1000;
  Future<void> mark(String name) async {
    final w = Stopwatch()..start();
    await AndroidModelWorker.channel.invokeMethod<Object?>('markMemoryTrace', {
      'phase': name,
    });
    controlMs += w.elapsedMicroseconds / 1000;
  }

  Future<T> stage<T>(
    String name,
    Future<T> Function() action, {
    bool userWait = false,
  }) async {
    phase = name;
    final begin = elapsedMs;
    await mark(name);
    try {
      return await action();
    } finally {
      stages.add({
        'name': name,
        'startMs': begin,
        'endMs': elapsedMs,
        'durationMs': elapsedMs - begin,
        'userWait': userWait,
      });
    }
  }

  Future<T> model<T>(
    String id,
    String operation,
    Future<T> Function() action,
  ) async {
    if (!watch.isRunning) return action();
    final begin = elapsedMs;
    await mark('$phase/$id/$operation');
    try {
      return await action();
    } finally {
      modelEvents.add({
        'modelId': id,
        'operation': operation,
        'startMs': begin,
        'endMs': elapsedMs,
        'durationMs': elapsedMs - begin,
      });
    }
  }
}

class FlowModelWorker implements ModelWorker {
  FlowModelWorker(this.trace);
  final FlowTrace trace;
  final delegate = AndroidModelWorker();
  String active = 'none';
  @override
  Future<void> load(String id, int threads) async {
    active = id;
    await trace.model(id, 'load', () => delegate.load(id, threads));
  }

  @override
  Future<Map<String, Object?>> infer(Map<String, Object?> input) =>
      trace.model(active, 'infer', () => delegate.infer(input));
  @override
  Future<void> unload() => trace.model(active, 'unload', delegate.unload);
  @override
  Future<void> reset() => trace.model(active, 'reset', delegate.reset);
}

Map<String, Object?> summarizeFlowTiming(
  double totalMs,
  List<Map<String, Object?>> stages,
) {
  final waiting = stages
      .where((s) => s['userWait'] == true)
      .fold<double>(0, (n, s) => n + (s['durationMs'] as num));
  final sum = stages.fold<double>(0, (n, s) => n + (s['durationMs'] as num));
  return {
    'wallTotalMs': totalMs,
    'userConfirmationWaitMs': waiting,
    'excludingUserWaitMs': totalMs - waiting,
    'stageTotalMs': sum,
    'unstagedOverheadMs': totalMs - sum,
  };
}
