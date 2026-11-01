import 'dart:io';

import 'package:drift/native.dart';

import 'data/adaptive_runtime.dart';
import 'data/store.dart';

Future<AppStore> oilProbeFixture(AdaptiveRuntime runtime, String id) async {
  final s = AppStore(clock: () => DateTime(2026, 10, 31, 12));
  await s.initialize(database: LocalDatabase(NativeDatabase.memory()));
  final v = Vehicle(
    id: id,
    model: '가상 렉스턴 2023 시험차',
    year: 2023,
    distance: 50000,
    hours: 1000,
    fuel: 3000,
    risk: 0,
  );
  await s.registerVehicle(v);
  await s.importKnowledge(
    KnowledgeBundle.decode(
      await File(runtime.modelInfo['knowledgePath'] as String).readAsString(),
    ),
  );
  final t = s.supportLibrary.knowledge.templates.single;
  await s.updateSupportLibrary(
    (lib) => lib.copyWith(
      rules: [
        MaintenanceRule(
          id: '$id-RULE',
          vehicleId: id,
          part: '오일필터',
          intervalKm: null,
          baselineKm: null,
          baselineDate: '',
          source: '가상 차량 시험용 적용조건 확인',
          conceptId: t['conceptId'] as String,
          templateId: t['id'] as String,
          applicabilityConfirmed: true,
          linkedAt: s.clock().toIso8601String(),
        ),
      ],
    ),
  );
  return s;
}
