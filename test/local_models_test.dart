import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/local_models.dart';
import 'package:military_maintenance/data/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('빠른 연속 기록 ID는 같은 시각에도 충돌하지 않는다', () {
    final store = AppStore(clock: () => DateTime(2026, 10, 9, 12));
    final ids = {for (var i = 0; i < 10000; i++) store.newId('PRED')};
    expect(ids.length, 10000);
    store.dispose();
  });

  test('동시 입력과 예측 불가 전환에서도 오래된 확률을 다시 표시하지 않는다', () async {
    final store = AppStore(clock: () => DateTime(2026, 10, 9, 12));
    await store.initialize(database: LocalDatabase(NativeDatabase.memory()));
    expect(store.error, isNull, reason: store.initializationCause?.toString());
    final first = store.vehicle('MOCK-RX-0001');
    final second = store.vehicle('MOCK-RX-0002');
    await Future.wait([
      store.updateOperation(
        first.id,
        first.year,
        first.distance + 1600,
        first.hours + 40,
        first.fuel + 160,
      ),
      store.updateOperation(
        second.id,
        second.year,
        second.distance + 2000,
        second.hours + 50,
        second.fuel + 220,
      ),
    ]);
    expect(
      store.predictions[first.id]!['features']['distanceKm'],
      first.distance + 1600,
    );
    expect(
      store.predictions[second.id]!['features']['distanceKm'],
      second.distance + 2000,
    );
    final third = store.vehicle('MOCK-RX-0003');
    await store.updateOperation(
      third.id,
      third.year,
      third.distance,
      third.hours,
      third.fuel,
    );
    expect(store.predictions.containsKey(third.id), isFalse);
    expect(store.vehicle(third.id).status, VehicleStatus.unavailable);
    await store.saveQuestion(third.id, '값이 없는 예측은 표시하지 않기');
    expect(store.predictions.containsKey(third.id), isFalse);
    await store.db!.close();
  });

  test('Python 학습 결과와 Dart 예측·분류·특성 계산이 일치한다', () async {
    final model = await LocalModels.load();
    final fixtures = jsonDecode(
      File('output/models/parity_fixtures.json').readAsStringSync(),
    ) as Map;
    for (final row in fixtures['prediction'] as List) {
      final features = Map<String, num>.from(row['features'] as Map);
      expect(
        model.predict(features),
        closeTo(row['probability'] as num, 1e-10),
      );
    }
    for (final row in fixtures['classification'] as List) {
      final result = model.classify(
        row['part'] as String,
        row['description'] as String,
      );
      for (final pair in [
        ('system', result.system),
        ('maintenanceType', result.type),
      ]) {
        final expected = row['expected'][pair.$1] as Map;
        expect(pair.$2.label, expected['label']);
        expect(
          pair.$2.confidence,
          closeTo(expected['confidence'] as num, 1e-10),
        );
        expect(pair.$2.coverage, closeTo(expected['coverage'] as num, 1e-10));
      }
    }
    final bootstrap = jsonDecode(
      await rootBundle.loadString('assets/mock/bootstrap.json'),
    ) as Map;
    for (final fixture in fixtures['appSnapshots'] as List) {
      final vehicle = (bootstrap['vehicles'] as List).firstWhere(
        (v) => v['id'] == fixture['vehicleId'],
      );
      final features = predictionFeatures(
        vehicle: Map<String, dynamic>.from(vehicle as Map),
        operations: (bootstrap['operations'] as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(),
        maintenance: (bootstrap['maintenance'] as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(),
        asOf: DateTime.parse(fixture['observedAt'] as String),
      );
      expect(features, fixture['features']);
      final futureMaintenance = {
        'vehicleId': fixture['vehicleId'],
        'date': '2026-10-15',
        'cost': 9999999,
        'maintenanceType': '고장수리',
      };
      final futureOperation = {
        'vehicleId': fixture['vehicleId'],
        'created': '2026-10-15T12:00:00',
        'distance': 9999999,
        'hours': 999999,
        'fuel': 999999,
      };
      final withoutFuture = predictionFeatures(
        vehicle: {...Map<String, dynamic>.from(vehicle), 'distance': 9999999},
        operations: [
          ...(bootstrap['operations'] as List).map(
            (r) => Map<String, dynamic>.from(r as Map),
          ),
          futureOperation,
        ],
        maintenance: [
          ...(bootstrap['maintenance'] as List).map(
            (r) => Map<String, dynamic>.from(r as Map),
          ),
          futureMaintenance,
        ],
        asOf: DateTime.parse(fixture['observedAt'] as String),
      );
      expect(
        withoutFuture,
        features,
        reason: '미래 기록과 차량 집계가 관측 특성에 들어가면 안 됩니다.',
      );
    }
  });

  test('입력 즉시 특성·예측·이력이 갱신되고 재실행에도 유지된다', () async {
    final folder = await Directory.systemTemp.createTemp('rexton-live-');
    final file = File('${folder.path}/live.sqlite');
    final now = DateTime(2026, 10, 9, 12);
    final store = AppStore(clock: () => now);
    await store.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(store.error, isNull);
    expect(store.predictions.length, 100);
    const id = 'MOCK-RX-0001';
    final initial = store.predictions[id]!;
    var notifications = 0;
    store.addListener(() => notifications++);
    final maintenanceWatch = Stopwatch()..start();
    await store.addMaintenance(
      const Maintenance(
        id: 'LIVE-MR',
        vehicleId: id,
        date: '2026-10-09',
        part: '브레이크 호스',
        system: '제동',
        description: '제동 압력 점검 이상으로 호스 교환',
        cost: 48000,
        maintenanceType: '고장수리',
      ),
    );
    maintenanceWatch.stop();
    final afterMaintenance = store.predictions[id]!;
    expect(notifications, 1);
    expect(afterMaintenance['trigger'], '정비 입력');
    expect(afterMaintenance['features']['daysSinceMaintenance'], 0);
    expect(
      afterMaintenance['features']['correctiveCount90Days'],
      (initial['features']['correctiveCount90Days'] as num) + 1,
    );
    expect(afterMaintenance['probability'], isNot(initial['probability']));
    expect(
      afterMaintenance['probability'],
      closeTo(
        store.models!.predict(
          Map<String, num>.from(afterMaintenance['features'] as Map),
        ),
        1e-10,
      ),
    );
    final old = store.vehicle(id);
    final operationWatch = Stopwatch()..start();
    await store.updateOperation(
      id,
      old.year,
      old.distance + 1600,
      old.hours + 40,
      old.fuel + 160,
    );
    operationWatch.stop();
    final afterOperation = store.predictions[id]!;
    expect(notifications, 2);
    expect(afterOperation['trigger'], '운용 입력');
    expect(afterOperation['features']['distanceKm'], old.distance + 1600);
    expect(afterOperation['features']['monthlyDistanceKm'], 1600);
    expect(
      afterOperation['probability'],
      isNot(afterMaintenance['probability']),
    );
    expect(
      store.vehicle(id).risk,
      ((afterOperation['probability'] as num) * 100).round(),
    );
    final historyCount = store.predictionHistory.length;
    final signature = afterOperation['id'];
    await store.db!.close();
    final reopened = AppStore(clock: () => now);
    await reopened.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(reopened.error, isNull);
    expect(reopened.predictions[id]!['id'], signature);
    expect(reopened.predictionHistory.length, historyCount);
    expect(
      reopened.predictions[id]!['probability'],
      afterOperation['probability'],
    );
    final timings = <int>[];
    for (var i = 0; i < 10; i++) {
      final v = reopened.vehicle(id);
      final watch = Stopwatch()..start();
      await reopened.updateOperation(
        id,
        v.year,
        v.distance + 50,
        v.hours + 2,
        v.fuel + 5,
      );
      watch.stop();
      timings.add(watch.elapsedMicroseconds);
      expect(
        reopened.predictions[id]!['features']['distanceKm'],
        v.distance + 50,
      );
    }
    timings.sort();
    final report = {
      'environment': 'Windows Flutter test runner; not Galaxy Tab hardware',
      'status': 'passed',
      'maintenanceSaveToPredictionMs':
          maintenanceWatch.elapsedMicroseconds / 1000,
      'operationSaveToPredictionMs': operationWatch.elapsedMicroseconds / 1000,
      'tenSequentialUpdatesP50Ms': timings[4] / 1000,
      'tenSequentialUpdatesP95Ms': timings[9] / 1000,
      'predictionsBefore': initial['probability'],
      'afterMaintenance': afterMaintenance['probability'],
      'afterOperation': afterOperation['probability'],
      'checks': [
        'listener notification',
        'fresh features',
        'fresh prediction',
        'history persistence',
        'restart idempotency',
        'ten consecutive local writes',
      ],
    };
    await File('output/models/live_update_report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    await reopened.db!.close();
    await folder.delete(recursive: true);
  });
}
