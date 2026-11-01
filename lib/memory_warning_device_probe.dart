import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/adaptive_runtime.dart';
import 'data/local_rag.dart';
import 'data/store.dart';
import 'probe_fixture.dart';

class WarningProbeWorker extends AndroidModelWorker {
  WarningProbeWorker(this.available, this.lowMemory, {this.afterLoad = false});
  final int available;
  final bool lowMemory, afterLoad;
  int loads = 0;
  Future<void> Function()? forwardFlutterPressure;
  Future<void> inject() =>
      forwardFlutterPressure?.call() ??
      AndroidModelWorker.channel.invokeMethod<void>('diagnosticTrim', {
        'level': 15,
        'availableBytes': available,
        'androidThresholdBytes': 384 * 1024 * 1024,
        'lowMemory': lowMemory,
      });
  @override
  Future<void> load(String modelId, int threads) async {
    loads++;
    await super.load(modelId, threads);
    if (afterLoad) await inject();
  }

  @override
  Future<Map<String, Object?>> infer(Map<String, Object?> input) async {
    if (afterLoad) return super.infer(input);
    final results = await Future.wait<Object?>([
      super.infer({...input, 'diagnosticHoldMs': 400}),
      Future<void>.delayed(const Duration(milliseconds: 40), inject),
    ]);
    return results.first as Map<String, Object?>;
  }
}

/// Debug-only memory snapshots; these are not physically reduced device RAM values.
Future<void> runMemoryWarningDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{
    'memorySource': 'debug_injected_policy_snapshot',
    'actualRamPressureExperiment': false,
    'cases': <Map<String, Object?>>[],
  };
  try {
    const mib = 1024 * 1024;
    for (final c in [
      {
        'id': 'flutter_callback_with_headroom',
        'available': 2048 * mib,
        'low': false,
        'gap': false,
        'fallback': false,
        'ui': true,
      },
      {
        'id': 'high_during_infer',
        'available': 2048 * mib,
        'low': false,
        'gap': false,
        'fallback': false,
      },
      {
        'id': 'high_between_load_infer',
        'available': 2048 * mib,
        'low': false,
        'gap': true,
        'fallback': false,
      },
      {
        'id': 'at_threshold_during_infer',
        'available': 512 * mib,
        'low': false,
        'gap': false,
        'fallback': true,
      },
      {
        'id': 'below_threshold_during_infer',
        'available': 511 * mib,
        'low': false,
        'gap': false,
        'fallback': true,
      },
      {
        'id': 'above_threshold_during_infer',
        'available': 512 * mib + 1,
        'low': false,
        'gap': false,
        'fallback': false,
      },
      {
        'id': 'low_flag_with_headroom',
        'available': 2048 * mib,
        'low': true,
        'gap': false,
        'fallback': true,
      },
    ]) {
      final worker = WarningProbeWorker(
        c['available'] as int,
        c['low'] as bool,
        afterLoad: c['gap'] as bool,
      );
      final runtime = AdaptiveRuntime(worker: worker, threads: 2);
      if (c['ui'] == true)
        worker.forwardFlutterPressure = runtime.memoryPressure;
      AppStore? store;
      try {
        await runtime.initialize();
        store = await oilProbeFixture(runtime, 'DEMO-WARNING-001');
        final result = await LocalRag(runtime)
            .search(store, 'DEMO-WARNING-001', '오일필터', '오일필터 분리 절차');
        final fallback = c['fallback'] as bool;
        if (result.evidence.isEmpty ||
            worker.loads != 1 ||
            result.mode != (fallback ? 'keyword_fallback' : 'hybrid')) {
          throw StateError('warning_integration_failed_${c['id']}');
        }
        final probe = await AndroidModelWorker.channel
            .invokeMapMethod<String, Object?>('probe');
        if (probe?['loaded'] != false) {
          throw StateError('warning_release_failed');
        }
        (report['cases'] as List).add({
          'id': c['id'],
          'decisionAvailableBytes': c['available'],
          'decisionLowMemory': c['low'],
          'expectedFallback': fallback,
          'mode': result.mode,
          'evidenceCount': result.evidence.length,
          'modelLoadCount': worker.loads,
          'afterRunModelUnloaded': true,
          'passed': true,
          'memorySource': c['ui'] == true
              ? 'observed_via_flutter_callback'
              : 'debug_injected',
          'failedThisSession': runtime.failedThisSession,
        });
      } finally {
        await runtime.manager.release();
        await store?.db?.close();
        runtime.dispose();
      }
    }
    report['status'] = 'passed';
  } catch (e) {
    report['status'] = 'failed';
    report['error'] = '$e';
  }
  await const MethodChannel('maintenance/device_probe')
      .invokeMethod<Object?>('complete', report);
}
