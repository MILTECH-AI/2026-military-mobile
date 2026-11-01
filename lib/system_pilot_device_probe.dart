import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/adaptive_runtime.dart';
import 'data/system_pilot.dart';
import 'data/model_execution.dart';

Future<void> runSystemPilotDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('maintenance/device_probe');
  final config = await channel.invokeMapMethod<String, Object?>('config') ?? {};
  final runtime = AdaptiveRuntime(threads: config['threads'] as int? ?? 2),
      report = <String, Object?>{'moduleName': maintenanceDecisionModuleName};
  try {
    await runtime.initialize();
    final d = runtime.device!;
    report['platform'] = d.isEmulator == true
        ? 'android-emulator'
        : 'android-device';
    report['physicalDevice'] = d.isEmulator == null ? null : !d.isEmulator!;
    report['device'] = {
      'api': d.androidApi,
      'ramBytes': d.totalRamBytes,
      'cores': d.cores,
      'abis': d.abis,
    };
    final path =
        (runtime.modelInfo['systemPilot'] as Map)['metadataPath'] as String;
    final appFiles = File(path).parent.parent.parent;
    final probes = jsonDecode(
      await File('${appFiles.path}/system-probes.json').readAsString(),
    ) as List;
    final cases = <Map<String, Object?>>[];
    report['cases'] = cases;
    for (final raw in probes) {
      final p = raw as Map,
          ids = systemFeatureIds(normalizeSystemText(p['text'] as String));
      if (jsonEncode(ids) != jsonEncode(p['featureIds'])) {
        throw StateError('feature parity mismatch');
      }
      final result = await SystemPilot.suggest(runtime, p['text'] as String);
      if (result.mode != 'suggestion_only' ||
          result.run?.output?['workerPid'] == pid) {
        throw StateError('real pilot inference failed');
      }
      final output = result.run!.output!,
          actual = (output['scores'] as List).cast<num>(),
          expected = (p['pcScores'] as List).cast<num>();
      double error = 0;
      for (var i = 0; i < actual.length; i++) {
        error = math.max(error, (actual[i] - expected[i]).abs().toDouble());
      }
      int best(List<num> v) => List.generate(
        v.length,
        (i) => i,
      ).reduce((a, b) => v[b] > v[a] ? b : a);
      cases.add({
        'id': p['id'],
        'featureIdsExact': true,
        'top1MatchesPc': true,
        'pcScores': expected,
        'androidScores': actual,
        'maxAbsScoreDifference': error,
        'proposals': result.labels,
        'timingsMs': result.run!.timingsMs,
        'pssKb': output['pssKb'],
      });
      if (best(actual) != best(expected)) {
        cases.last['top1MatchesPc'] = false;
        throw StateError('PC Android class rank mismatch: ${p['id']}');
      }
    }
    final released = await AndroidModelWorker.channel
        .invokeMapMethod<String, Object?>('probe');
    if (released?['loaded'] != false) throw StateError('pilot unload failed');
    report['cases'] = cases;
    report['afterUnload'] = released;
    report['model'] = runtime.modelInfo['systemPilot'];
    report['purpose'] = 'runtime parity with PC full-fit model; NOT held-out accuracy evaluation';
    report['sourceStatus'] = 'authorship_unconfirmed';
    report['labelStatus'] = 'single_ai_draft_not_human_reviewed';
    report['status'] = 'passed';
  } catch (e) {
    report['status'] = 'failed';
    report['error'] = '$e';
  } finally {
    await runtime.manager.release();
    runtime.dispose();
  }
  await channel.invokeMethod<Object?>('complete', report);
}
