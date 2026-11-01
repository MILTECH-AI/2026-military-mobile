import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('렉스턴 학습 표본은 가상 출처와 차량별 분할을 유지한다', () {
    final rows = File('data/mock/training.jsonl')
        .readAsLinesSync()
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(rows.length, 24000);
    final splits = <String, String>{};
    final counts = <String, int>{};
    final ids = <String>{};
    final labels = <int>{};
    for (final row in rows) {
      expect(row['source'], 'synthetic');
      expect(row['isSynthetic'], isTrue);
      expect(ids.add(row['id'] as String), isTrue);
      final vehicle = row['vehicleId'] as String;
      final split = row['split'] as String;
      expect(vehicle, startsWith('MOCK-RX-'));
      expect(splits.putIfAbsent(vehicle, () => split), split);
      counts[split] = (counts[split] ?? 0) + 1;
      final features = row['features'] as Map<String, dynamic>;
      expect(features.length, 14);
      expect(features.containsKey('risk'), isFalse);
      expect(features.containsKey('coolantTemperatureC'), isFalse);
      expect(features['distanceKm'], greaterThan(0));
      expect(
        DateTime.parse(row['labelWindowEnd'] as String)
            .isAfter(DateTime.parse(row['observedAt'] as String)),
        isTrue,
      );
      labels.add(
        (row['label'] as Map)['correctiveMaintenanceNextMonth'] as int,
      );
    }
    expect(splits.length, 500);
    expect(counts, {'train': 16800, 'validation': 3600, 'test': 3600});
    expect(labels, {0, 1});
  });
}
