import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'data/local_models.dart';

/// Explicit androidTest entry point. Only reads separately provisioned QA input.
Future<void> runMlDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('maintenance/device_probe');
  final report = <String, Object?>{'scope': 'synthetic_heldout_runtime_parity'};
  try {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/ml-qa-probes.json');
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('qa_input_limit');
    }
    final data = jsonDecode(await file.readAsString()) as Map;
    if (data['format'] != 'synthetic-model-qa' || data['isSynthetic'] != true) {
      throw const FormatException('synthetic_input_required');
    }
    final model = await LocalModels.load();
    if (data['modelVersions']['prediction'] != model.prediction['version'] ||
        data['modelVersions']['classification'] !=
            model.classification['version']) {
      throw const FormatException('model_version_mismatch');
    }
    final predictions = data['prediction'] as List;
    final classifications = data['classification'] as List;
    if (predictions.length != 3600 || classifications.length != 861) {
      throw const FormatException('qa_case_count');
    }
    double numericError = 0, textError = 0;
    final watch = Stopwatch()..start();
    for (final raw in predictions) {
      final row = raw as Map;
      final actual = model.predict(
        Map<String, num>.from(row['features'] as Map),
      );
      final delta = (actual - (row['expected'] as num)).abs();
      if (!actual.isFinite || !delta.isFinite || delta > 1e-10) {
        throw const FormatException('prediction_parity');
      }
      numericError = math.max(numericError, delta);
    }
    final numericMs = watch.elapsedMicroseconds / 1000;
    watch.reset();
    for (final raw in classifications) {
      final row = raw as Map;
      final actual = model.classify(
        row['part'] as String,
        row['description'] as String,
      );
      for (final head in [
        ('system', actual.system),
        ('maintenanceType', actual.type),
      ]) {
        final expected = row['expected'][head.$1] as Map;
        final confidence =
            (head.$2.confidence - (expected['confidence'] as num)).abs();
        final coverage = (head.$2.coverage - (expected['coverage'] as num))
            .abs();
        if (head.$2.label != expected['label'] ||
            !confidence.isFinite ||
            !coverage.isFinite ||
            confidence > 1e-10 ||
            coverage > 1e-10) {
          throw const FormatException('classification_parity');
        }
        textError = math.max(textError, math.max(confidence, coverage));
      }
    }
    report.addAll({
      'status': 'passed',
      'predictionCases': predictions.length,
      'classificationCases': classifications.length,
      'predictionMaxAbsError': numericError,
      'classificationMaxAbsError': textError,
      'predictionTotalMs': numericMs,
      'classificationTotalMs': watch.elapsedMicroseconds / 1000,
      'timingScope': 'single debug batch; not production latency benchmark',
      'persistentDatabaseTouched': false,
    });
  } catch (error) {
    report.addAll({
      'status': 'failed',
      'errorType': error.runtimeType.toString(),
    });
  }
  await channel.invokeMethod<Object?>('complete', report);
}
