import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';

const realVehicle = Vehicle(
  id: '시험12가3456',
  model: '등록 시험 차량',
  year: 2020,
  distance: 20000,
  hours: 500,
  fuel: 1000,
  risk: 0,
);
const cycle = MaintenanceRule(
  id: 'CYCLE',
  vehicleId: '시험12가3456',
  part: '엔진오일',
  intervalKm: 5000,
  baselineKm: 13000,
  baselineDate: '2026-10-01',
  source: '가상 시험 주기',
);
Maintenance replacement({
  String id = 'REPLACE',
  int km = 20000,
  String date = '2026-10-09',
  String? inspection,
}) => Maintenance(
  id: id,
  vehicleId: realVehicle.id,
  date: date,
  part: 'engine_oil',
  system: '엔진/연료',
  description: '가상 교환 완료 $id',
  cost: 10000,
  maintenanceType: '예방',
  replacementCompleted: true,
  odometerKm: km,
  inspectionId: inspection,
);

Future<AppStore> initialized() async {
  final s = AppStore(clock: () => DateTime(2026, 10, 14, 12));
  await s.initialize(database: LocalDatabase(NativeDatabase.memory()));
  expect(s.error, isNull);
  addTearDown(() => s.db!.close());
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('등록 차량과 초기 계기를 함께 보관하며 예제 예측을 적용하지 않는다', () async {
    final s = await initialized();
    await s.registerVehicle(realVehicle);
    expect(s.registeredVehicles.single.id, realVehicle.id);
    expect(s.activeVehicles.length, 1);
    expect(
      s.operations
          .where((o) => o['vehicleId'] == realVehicle.id)
          .single['distance'],
      20000,
    );
    expect(s.vehicle(realVehicle.id).predictionReady, isFalse);
    expect(s.predictions.containsKey(realVehicle.id), isFalse);
    await expectLater(s.registerVehicle(realVehicle), throwsArgumentError);
    expect(s.registeredVehicles.length, 1);
  });

  test('차량 등록 중 운용 기록 저장 실패 시 차량도 남기지 않는다', () async {
    final s = await initialized();
    await s.db!.customStatement(
      "CREATE TRIGGER fail_real BEFORE INSERT ON operations WHEN NEW.vehicle_id = '시험12가3456' BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
    );
    await expectLater(
      s.registerVehicle(realVehicle),
      throwsA(isA<Exception>()),
    );
    final rows = await s.db!
        .customSelect("SELECT id FROM vehicles WHERE id = '시험12가3456'")
        .get();
    expect(rows, isEmpty);
    expect(s.registeredVehicles, isEmpty);
  });

  test('교환 완료·수정·삭제에 따라 잔여 거리가 함께 재계산된다', () async {
    final s = await initialized();
    await s.registerVehicle(realVehicle);
    await s.saveSupportLibrary(const SupportLibrary(rules: [cycle]));
    expect(s.serviceDistance(cycle).remainingKm, 0);
    await s.addMaintenance(replacement());
    expect(s.serviceDistance(cycle).remainingKm, 5000);
    expect(s.serviceDistance(cycle).recordId, 'REPLACE');
    await s.updateOperation(realVehicle.id, 2020, 20500, 510, 1100);
    expect(s.serviceDistance(cycle).remainingKm, 4500);
    await s.editMaintenance(replacement(km: 19800));
    expect(s.serviceDistance(cycle).remainingKm, 4300);
    await s.deleteMaintenance('REPLACE');
    expect(s.serviceDistance(cycle).remainingKm, 0);
    expect(s.serviceDistance(cycle).recordId, isNull);
  });

  test('점검만 기록하면 주기를 유지하고 알 수 없는 과거 기록은 확인을 요청한다', () async {
    final s = await initialized();
    await s.registerVehicle(realVehicle);
    await s.saveSupportLibrary(const SupportLibrary(rules: [cycle]));
    await s.addMaintenance(replacement());
    await s.addMaintenance(
      const Maintenance(
        id: 'CHECK',
        vehicleId: '시험12가3456',
        date: '2026-10-10',
        part: '엔진오일',
        system: '엔진/연료',
        description: '누유 점검만 시행',
        cost: 0,
        replacementCompleted: false,
      ),
    );
    expect(s.serviceDistance(cycle).remainingKm, 5000);
    await s.addMaintenance(
      const Maintenance(
        id: 'LEGACY',
        vehicleId: '시험12가3456',
        date: '2026-10-11',
        part: '엔진오일',
        system: '엔진/연료',
        description: '교환 여부 미상 과거 기록',
        cost: 0,
      ),
    );
    expect(s.serviceDistance(cycle).remainingKm, isNull);
    expect(s.serviceDistance(cycle).reason, contains('갱신'));
  });

  test('다른 차량의 점검 연결과 앞뒤가 맞지 않는 교환 계기를 거부한다', () async {
    final s = await initialized();
    await s.registerVehicle(realVehicle);
    final mock = s.vehicles.firstWhere((v) => v.id.startsWith('MOCK-'));
    await s.saveInspection(
      Inspection(
        id: 'OTHER-PHOTO',
        vehicleId: mock.id,
        area: '엔진오일',
        mode: '부품 촬영',
        created: '2026-10-09T10:00:00',
        imagePath: 'not-used.jpg',
        note: '',
      ),
    );
    await expectLater(
      s.addMaintenance(replacement(inspection: 'OTHER-PHOTO')),
      throwsArgumentError,
    );
    await expectLater(
      s.addMaintenance(replacement(km: 20001)),
      throwsArgumentError,
    );
    await s.addMaintenance(replacement());
    await expectLater(
      s.addMaintenance(
        replacement(id: 'BACKWARDS', km: 19000, date: '2026-10-10'),
      ),
      throwsArgumentError,
    );
    expect(s.history(realVehicle.id).length, 1);
  });

  test('한글 차량번호·점검 사진·교환 계기·다음 계획을 백업 복원 후 유지한다', () async {
    final s = await initialized();
    await s.registerVehicle(realVehicle);
    final dir = await Directory.systemTemp.createTemp('completion-backup-');
    addTearDown(() => dir.delete(recursive: true));
    await s.saveSupportLibrary(const SupportLibrary(rules: [cycle]));
    await s.saveInspection(
      Inspection(
        id: 'PHOTO-COMPLETE',
        vehicleId: realVehicle.id,
        area: '엔진오일',
        mode: '부품 촬영',
        created: '2026-10-09T10:00:00',
        imagePath: File('assets/figma/ed09d.png').absolute.path,
        note: '가상 점검 메모',
      ),
    );
    await s.addMaintenance(replacement(inspection: 'PHOTO-COMPLETE'));
    final file = File('${dir.path}/roundtrip.mbackup');
    await s.exportBackup(file);
    final snapshot = await BackupSnapshot.read(file);
    await s.deleteMaintenance('REPLACE');
    await s.restoreBackup(snapshot, Directory('${dir.path}/photos'));
    final restored = s.records.firstWhere((r) => r.id == 'REPLACE');
    expect(restored.inspectionId, 'PHOTO-COMPLETE');
    expect(restored.odometerKm, 20000);
    expect(restored.replacementCompleted, isTrue);
    expect(s.serviceDistance(cycle).remainingKm, 5000);
    expect(await File(s.inspections.single.imagePath).exists(), isTrue);
    final bad = jsonDecode(
      utf8.decode(gzip.decode(await file.readAsBytes())),
    ) as Map<String, dynamic>;
    final row = (bad['tables']['maintenance'] as List).firstWhere(
      (r) => r['id'] == 'REPLACE',
    );
    row['inspectionId'] = 'MISSING';
    final broken = File('${dir.path}/broken.mbackup');
    await broken.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(bad))));
    await expectLater(BackupSnapshot.read(broken), throwsFormatException);
  });
}
