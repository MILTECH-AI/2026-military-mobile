import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final appMaintenanceCount = (jsonDecode(
    File('data/mock/manifest.json').readAsStringSync(),
  ) as Map)['appCounts']['maintenance'];
  test('v2 목업 갱신은 로컬 입력 차량을 보호하고 미수정 차량만 교체한다', () async {
    final folder = await Directory.systemTemp.createTemp('military-v3-');
    final file = File('${folder.path}/migration.sqlite');
    final first = AppStore(clock: () => DateTime(2026, 10, 9, 12));
    await first.initialize(database: LocalDatabase(NativeDatabase(file)));
    final untouched = first.vehicle('MOCK-RX-0001');
    final protected = first.vehicle('MOCK-RX-0002');
    await first.updateOperation(
      protected.id,
      protected.year,
      protected.distance + 1700,
      protected.hours + 50,
      protected.fuel + 180,
    );
    final protectedOperations = first.operations
        .where((r) => r['vehicleId'] == protected.id)
        .length;
    final oldRecord = await first.db!
        .customSelect('SELECT payload FROM maintenance LIMIT 1')
        .getSingle();
    final oldValue =
        jsonDecode(oldRecord.read<String>('payload')) as Map<String, dynamic>;
    oldValue['id'] = 'OLD-V2-RECORD';
    oldValue['vehicleId'] = untouched.id;
    oldValue['datasetVersion'] = 'rexton-mock-v2';
    await first.db!.customStatement(
      'INSERT INTO maintenance (id,vehicle_id,payload) VALUES (?,?,?)',
      ['OLD-V2-RECORD', untouched.id, jsonEncode(oldValue)],
    );
    final rows = await first.db!
        .customSelect('SELECT id,payload FROM vehicles')
        .get();
    for (final row in rows) {
      if (row.read<String>('id') != untouched.id) continue;
      final value =
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      value['datasetVersion'] = 'rexton-mock-v2';
      value['distance'] = 888;
      await first.db!.customStatement(
        'UPDATE vehicles SET payload = ? WHERE id = ?',
        [jsonEncode(value), untouched.id],
      );
    }
    await first.db!.customStatement(
      'UPDATE app_metadata SET value = ? WHERE key = ?',
      ['rexton-mock-v2', 'mock_dataset'],
    );
    await first.db!.close();
    final reopened = AppStore(clock: () => DateTime(2026, 10, 9, 12));
    await reopened.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(reopened.error, isNull);
    expect(reopened.vehicle(untouched.id).distance, untouched.distance);
    expect(reopened.vehicle(protected.id).distance, protected.distance + 1700);
    expect(
      reopened.operations.where((r) => r['vehicleId'] == protected.id).length,
      protectedOperations,
    );
    expect(reopened.records.any((r) => r.id == 'OLD-V2-RECORD'), isFalse);
    expect(
      reopened.predictions[untouched.id]!['trainedOn'],
      'synthetic rexton-mock-v3',
    );
    await reopened.db!.close();
    await folder.delete(recursive: true);
  });
  test('이전 DB의 사용자 기록을 유지하며 렉스턴 목업을 한 번 추가한다', () async {
    final folder = await Directory.systemTemp.createTemp('military-migration-');
    final file = File('${folder.path}/legacy.sqlite');
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute(
      'CREATE TABLE vehicles (id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );
    for (final table in [
      'maintenance',
      'operations',
      'inspections',
      'questions',
    ]) {
      legacy.execute(
        'CREATE TABLE $table (id TEXT PRIMARY KEY, vehicle_id TEXT NOT NULL REFERENCES vehicles(id), payload TEXT NOT NULL)',
      );
    }
    legacy.execute('INSERT INTO vehicles VALUES (?,?)', [
      'LEGACY-V',
      jsonEncode({
        'id': 'LEGACY-V',
        'model': '기존 입력',
        'year': 2020,
        'distance': 12345,
        'hours': 400,
        'fuel': 1200,
        'risk': 12,
      }),
    ]);
    legacy.execute('PRAGMA user_version = 1');
    legacy.close();
    final store = AppStore();
    await store.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(store.error, isNull);
    expect(store.vehicles.length, 101);
    expect(store.vehicle('LEGACY-V').distance, 12345);
    expect(store.records.length, appMaintenanceCount);
    await store.db!.close();
    final reopened = AppStore();
    await reopened.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(reopened.error, isNull);
    expect(reopened.vehicles.length, 101);
    expect(reopened.records.length, appMaintenanceCount);
    expect(reopened.operations.length, 2400);
    await reopened.db!.close();
    await folder.delete(recursive: true);
  });
  test('정비·운용실적 저장은 재실행 후 유지되고 누적값 감소는 거부된다', () async {
    final folder = await Directory.systemTemp.createTemp('military-test-');
    final file = File('${folder.path}/store.sqlite');
    final first = AppStore();
    await first.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(first.error, isNull);
    expect(first.vehicles.length, 100);
    expect(first.operations.length, 2400);
    final seeded = await first.db!
        .customSelect('SELECT payload FROM vehicles LIMIT 1')
        .getSingle();
    expect(seeded.read<String>('payload'), contains('"isSynthetic":true'));
    final old = first.vehicle('MOCK-RX-0001');
    final originalRecords = first.records.length;
    await first.addMaintenance(
      const Maintenance(
        id: 'TEST-MR',
        vehicleId: 'MOCK-RX-0001',
        date: '2026-10-09',
        part: '시험 부속',
        system: '냉각',
        description: '저장 검증 기록',
        cost: 123000,
      ),
    );
    await expectLater(
      first.updateOperation(
        old.id,
        old.year,
        old.distance - 1,
        old.hours,
        old.fuel,
      ),
      throwsArgumentError,
    );
    await first.updateOperation(
      old.id,
      old.year,
      old.distance + 100,
      old.hours + 2,
      old.fuel + 10,
    );
    expect(first.records.length, originalRecords + 1);
    await first.saveQuestion(old.id, '저장된 질문 확인');
    final image = File('${folder.path}/local-capture.jpg');
    await image.writeAsBytes([255, 216, 255, 217]);
    await first.saveInspection(
      Inspection(
        id: 'TEST-VS',
        vehicleId: old.id,
        area: '외관',
        mode: '차량 촬영',
        created: '2026-10-09T12:00:00',
        imagePath: image.path,
        note: '로컬 점검 메모',
      ),
    );
    await first.db!.close();
    final second = AppStore();
    await second.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(second.error, isNull);
    expect(second.vehicle(old.id).distance, old.distance + 100);
    expect(second.records.first.id, 'TEST-MR');
    expect(second.records.length, originalRecords + 1);
    expect(second.operations.length, 2401);
    expect(second.operations.first['vehicleId'], old.id);
    expect(second.operations.first['source'], 'local_input');
    expect(second.operations.first['isSynthetic'], isNull);
    expect(second.questions.single['question'], '저장된 질문 확인');
    expect(second.inspections.single.note, '로컬 점검 메모');
    expect(await File(second.inspections.single.imagePath).readAsBytes(), [
      255,
      216,
      255,
      217,
    ]);
    await second.db!.close();
    await folder.delete(recursive: true);
  });
}
