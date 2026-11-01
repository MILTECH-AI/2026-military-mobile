import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';

import 'knowledge_import_test.dart'
    show bundleJson, fixtureVehicle, fixtureRule;

const row = Maintenance(
  id: 'CONFIRM-TEST',
  vehicleId: 'RULE-TEST-1',
  date: '2026-10-01',
  part: 'fixture_filter',
  system: '엔진/연료',
  description: '가상 교환 기록',
  cost: 0,
  replacementCompleted: true,
  odometerKm: 2000,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore s;
  var now = DateTime(2026, 10, 9);
  setUp(() async {
    now = DateTime(2026, 10, 9);
    s = AppStore(clock: () => now);
    await s.initialize(database: LocalDatabase(NativeDatabase.memory()));
    await s.registerVehicle(fixtureVehicle);
    await s.importKnowledge(KnowledgeBundle.decode(jsonEncode(bundleJson())));
    await s.selectServicePolicy('normal');
    await s.updateSupportLibrary((lib) => lib.copyWith(rules: [fixtureRule()]));
  });
  tearDown(() => s.db!.close());
  test('이름 일치·입력 객체의 확정값만으로 자동 연결하지 않고 계산은 보류한다', () async {
    await s.addMaintenance(
      Maintenance.fromJson({
        ...row.toJson(),
        'conceptId': 'FILTER',
        'conceptConfirmedAt': '2026-01-01T00:00:00',
      }),
    );
    final saved = s.records.singleWhere((r) => r.id == row.id);
    expect(saved.conceptId, isNull);
    expect(saved.conceptConfirmedAt, isNull);
    expect(s.relatedMaintenance(row.vehicleId, '시험필터', ''), isEmpty);
    expect(
      s
          .relatedMaintenance(
            row.vehicleId,
            '시험필터',
            '',
            includeCandidates: true,
          )
          .map((r) => r.id),
      contains(row.id),
    );
    expect(s.serviceDistance(fixtureRule()).reason, contains('부품 개념 연결 미확인'));
    expect(s.serviceDistance(fixtureRule()).remainingKm, isNull);
    expect(
      s.serviceDistance(fixtureRule()).blockingRecordIds,
      contains(row.id),
    );
  });
  test('명시적 확인 후 계산·이력 연결, 다른 필드 수정 시 원래 확인시각 유지', () async {
    await s.addMaintenance(row, confirmedConceptId: 'FILTER');
    final saved = s.records.singleWhere((r) => r.id == row.id);
    expect(saved.confirmedConceptId, 'FILTER');
    expect(s.serviceDistance(fixtureRule()).baselineKm, 2000);
    expect(s.relatedMaintenance(row.vehicleId, '시험필터', '').single.id, row.id);
    now = DateTime(2026, 10, 10);
    await s.editMaintenance(
      Maintenance.fromJson({...saved.toJson(), 'description': '가상 메모 수정'}),
    );
    expect(
      s.records.singleWhere((r) => r.id == row.id).conceptConfirmedAt,
      saved.conceptConfirmedAt,
    );
    await s.editMaintenance(
      Maintenance.fromJson({...saved.toJson(), 'part': '시험필터 하우징'}),
    );
    expect(
      s.records.singleWhere((r) => r.id == row.id).confirmedConceptId,
      isNull,
    );
  });
  test('확인 해제·존재하지 않는 개념 거부·과거 자동 연결은 미확인으로 취급한다', () async {
    await expectLater(
      s.addMaintenance(row, confirmedConceptId: 'MISSING'),
      throwsFormatException,
    );
    await s.addMaintenance(row, confirmedConceptId: 'FILTER');
    await s.editMaintenance(row, clearConcept: true);
    expect(s.records.singleWhere((r) => r.id == row.id).conceptId, isNull);
    final legacy = Maintenance.fromJson({
      ...row.toJson(),
      'conceptId': 'FILTER',
    });
    expect(legacy.confirmedConceptId, isNull);
    expect(s.recordMatchesConcept(legacy, fixtureRule()), isFalse);
    expect(s.recordIsConceptCandidate(legacy, fixtureRule()), isTrue);
  });
}
