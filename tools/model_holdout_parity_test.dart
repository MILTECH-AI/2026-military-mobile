// Prepare with tools/evaluate_saved_models.py; this is an explicit QA command.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/local_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('전체 합성 홀드아웃에서 Python과 Dart의 예측·분류 출력이 일치한다', () async {
    final dir = Platform.environment['ML_QA_DIR'] ?? 'output/model-qa';
    final parity =
        jsonDecode(File('$dir/parity.json').readAsStringSync()) as Map;
    final model = await LocalModels.load();
    expect(parity['modelVersions']['prediction'], model.prediction['version']);
    expect(
      parity['modelVersions']['classification'],
      model.classification['version'],
    );
    List<Map<String, dynamic>> rows(String task) =>
        File('data/mock/$task/test.jsonl')
            .readAsLinesSync()
            .map((s) => jsonDecode(s) as Map<String, dynamic>)
            .toList();
    final prediction = rows('prediction');
    expect(prediction.length, (parity['prediction'] as List).length);
    for (var i = 0; i < prediction.length; i++) {
      expect(
        model.predict(Map<String, num>.from(prediction[i]['features'] as Map)),
        closeTo(parity['prediction'][i] as num, 1e-10),
        reason: 'prediction row $i',
      );
    }
    final classification = rows('classification');
    expect(classification.length, (parity['classification'] as List).length);
    for (var i = 0; i < classification.length; i++) {
      final input = classification[i]['input'] as Map;
      final actual = model.classify(
        input['part'] as String,
        input['description'] as String,
      );
      for (final head in [
        ('system', actual.system),
        ('maintenanceType', actual.type),
      ]) {
        final expected = parity['classification'][i][head.$1] as Map;
        expect(
          head.$2.label,
          expected['label'],
          reason: 'classification row $i',
        );
        expect(
          head.$2.confidence,
          closeTo(expected['confidence'] as num, 1e-10),
        );
        expect(head.$2.coverage, closeTo(expected['coverage'] as num, 1e-10));
      }
    }
  });
}
