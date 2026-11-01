import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/data/local_models.dart';

Future<AppStore> createStore([File? file]) async {
  final store = AppStore(clock: () => DateTime(2026, 10, 9, 12));
  await store.initialize(
    database: LocalDatabase(
      file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ),
  );
  expect(store.error, isNull, reason: store.initializationCause?.toString());
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('변경 이력은 같은 시각의 수정도 최신순으로 전체 페이지를 조회한다', () async {
    final s = await createStore();
    addTearDown(() => s.db!.close());
    final r = s.records.firstWhere((r) => r.vehicleId == 'MOCK-RX-0001');
    for (var i = 1; i <= 14; i++) {
      await s.editMaintenance(
        Maintenance.fromJson({...r.toJson(), 'cost': r.cost + i}),
      );
    }
    final first = await s.recordChanges(r.vehicleId);
    final second = await s.recordChanges(r.vehicleId, page: 1);
    expect(first.total, 14);
    expect(first.rows.length, 12);
    expect(second.rows.length, 2);
    expect((first.rows.first['after'] as Map)['cost'], r.cost + 14);
    expect((second.rows.last['before'] as Map)['cost'], r.cost);
    expect((await s.recordChanges('MOCK-RX-0002')).total, 0);
    await expectLater(
      s.recordChanges(r.vehicleId, page: -1),
      throwsArgumentError,
    );
  });

  test('주행에 대응하는 유류 증가가 없으면 분석 보류하고 수정 후 회복한다', () async {
    final s = await createStore();
    addTearDown(() => s.db!.close());
    const id = 'MOCK-RX-0001';
    final rows = s.operations.where((r) => r['vehicleId'] == id).toList()
      ..sort(
        (a, b) => (a['created'] as String).compareTo(b['created'] as String),
      );
    final latest = rows.last;
    final previous = rows[rows.length - 2];
    await s.editOperation(
      latest['id'] as String,
      latest['distance'] as int,
      latest['hours'] as int,
      previous['fuel'] as int,
    );
    expect(s.vehicle(id).predictionReady, isFalse);
    expect(s.predictionUnavailableReason(id), contains('시간·유류'));
    final row = await s.db!
        .customSelect(
          'SELECT payload FROM predictions WHERE vehicle_id = ? ORDER BY rowid DESC LIMIT 1',
          variables: [Variable<String>(id)],
        )
        .getSingle();
    expect(
      jsonDecode(row.read<String>('payload'))['unavailableReason'],
      s.predictionUnavailableReason(id),
    );
    await s.editOperation(
      latest['id'] as String,
      latest['distance'] as int,
      latest['hours'] as int,
      latest['fuel'] as int,
    );
    expect(s.vehicle(id).predictionReady, isTrue);
    final malformed = assessPrediction(
      vehicle: s.vehicle(id).toJson(),
      operations: [
        {...latest, 'distance': double.nan},
      ],
      maintenance: [],
      asOf: s.clock(),
    );
    expect(malformed.features, isNull);
    expect(malformed.reason, contains('누적값'));
    expect(
      assessPrediction(
        vehicle: s.vehicle(id).toJson(),
        operations: [],
        maintenance: [],
        asOf: s.clock(),
      ).reason,
      contains('없습니다'),
    );
  });
  test('정비 수정·삭제와 중복·미래 날짜 검사는 예측 및 변경 이력에 반영된다', () async {
    final s = await createStore();
    addTearDown(() => s.db!.close());
    final id = s.newId('MR');
    final value = Maintenance(
      id: id,
      vehicleId: 'MOCK-RX-0001',
      date: '2026-10-09',
      part: '가상 호스',
      system: '냉각',
      description: '가상 점검 결과',
      cost: 12000,
      maintenanceType: '고장수리',
    );
    await s.addMaintenance(value);
    final before = s.predictions[value.vehicleId]!;
    final changed = Maintenance.fromJson({
      ...value.toJson(),
      'cost': 25000,
      'maintenanceType': '예방',
      'date': '2026-10-08',
    });
    await s.editMaintenance(changed);
    expect(s.records.singleWhere((r) => r.id == id).cost, 25000);
    expect(s.predictions[value.vehicleId]!['trigger'], '정비 수정');
    expect(
      s.predictions[value.vehicleId]!['features'],
      isNot(before['features']),
    );
    await expectLater(
      s.addMaintenance(
        Maintenance.fromJson({...changed.toJson(), 'id': s.newId('MR')}),
      ),
      throwsArgumentError,
    );
    for (final date in ['2026-10-10', '2026-02-30', '2000-01-01']) {
      await expectLater(
        s.editMaintenance(
          Maintenance.fromJson({...changed.toJson(), 'date': date}),
        ),
        throwsArgumentError,
      );
    }
    await s.deleteMaintenance(id);
    expect(s.records.any((r) => r.id == id), isFalse);
    expect(s.predictions[value.vehicleId]!['trigger'], '정비 삭제');
    final logs = await s.db!
        .customSelect('SELECT payload FROM record_changes ORDER BY rowid')
        .get();
    expect(logs.length, 2);
    final first = jsonDecode(logs.first.read<String>('payload')) as Map;
    expect(first['before']['cost'], 12000);
    expect(first['after']['cost'], 25000);
    expect(
      (jsonDecode(logs.last.read<String>('payload')) as Map)['after'],
      isNull,
    );
  });

  test('과거 운용 수정은 앞뒤 누적값을 검사하고 최신 삭제는 이전 누적값을 복구한다', () async {
    final s = await createStore();
    addTearDown(() => s.db!.close());
    const id = 'MOCK-RX-0002';
    final old = s.vehicle(id);
    await s.updateOperation(
      id,
      old.year,
      old.distance + 1000,
      old.hours + 30,
      old.fuel + 120,
    );
    final op = s.operations.firstWhere((r) => r['vehicleId'] == id);
    await s.updateOperation(
      id,
      old.year,
      old.distance + 2000,
      old.hours + 60,
      old.fuel + 240,
    );
    final latest = s.operations.firstWhere((r) => r['vehicleId'] == id);
    await expectLater(
      s.editOperation(
        op['id'] as String,
        old.distance + 3000,
        old.hours + 30,
        old.fuel + 120,
      ),
      throwsArgumentError,
    );
    await s.editOperation(
      op['id'] as String,
      old.distance + 900,
      old.hours + 29,
      old.fuel + 110,
    );
    expect(s.vehicle(id).distance, old.distance + 2000);
    await s.deleteOperation(latest['id'] as String);
    expect(s.vehicle(id).distance, old.distance + 900);
    expect(s.predictions[id]!['trigger'], '운용 삭제');
    await s.deleteOperation(op['id'] as String);
    expect(s.vehicle(id).distance, old.distance);
  });

  test('백업 왕복은 사진·동일시각 기록 순서·삭제 이력·재실행 상태를 보존한다', () async {
    final dir = await Directory.systemTemp.createTemp('backup-roundtrip-');
    addTearDown(() => dir.delete(recursive: true));
    final db = File('${dir.path}/store.sqlite');
    final s = await createStore(db);
    const vid = 'MOCK-RX-0001';
    final old = s.vehicle(vid);
    await s.updateOperation(
      vid,
      old.year,
      old.distance + 1000,
      old.hours + 30,
      old.fuel + 130,
    );
    await s.updateOperation(
      vid,
      old.year,
      old.distance + 1500,
      old.hours + 40,
      old.fuel + 180,
    );
    final removed = s.history(vid).first.id;
    await s.deleteMaintenance(removed);
    await s.saveQuestion(vid, '가상 질문');
    final photo = File('${dir.path}/original.jpg');
    final bytes = List<int>.generate(128, (i) => i);
    await photo.writeAsBytes(bytes);
    await s.saveInspection(
      Inspection(
        id: 'TEST-PHOTO',
        vehicleId: vid,
        area: '가상 영역',
        mode: '수동',
        created: '2026-10-09T12:00:00',
        imagePath: photo.path,
        note: '가상 메모',
      ),
    );
    final backup = File('${dir.path}/snapshot.mbackup');
    final originalProbability = s.predictions[vid]!['probability'];
    await Future.wait([
      s.exportBackup(backup),
      s.updateOperation(
        vid,
        old.year,
        old.distance + 2000,
        old.hours + 50,
        old.fuel + 230,
      ),
    ]);
    final raw = utf8.decode(gzip.decode(await backup.readAsBytes()));
    expect(raw.contains(photo.path), isFalse);
    final snapshot = await BackupSnapshot.read(backup);
    expect(snapshot.photos['TEST-PHOTO'], bytes);
    await photo.delete();
    await s.restoreBackup(snapshot, Directory('${dir.path}/restored-images'));
    expect(s.vehicle(vid).distance, old.distance + 1500);
    expect(s.predictions[vid]!['probability'], originalProbability);
    expect(s.records.any((r) => r.id == removed), isFalse);
    final restoredPhoto = s.inspections.single;
    expect(restoredPhoto.imagePath, isNot(photo.path));
    expect(await File(restoredPhoto.imagePath).readAsBytes(), bytes);
    expect(s.questions.single['question'], '가상 질문');
    final count = s.records.length;
    await s.db!.close();
    final reopened = await createStore(db);
    expect(reopened.records.length, count);
    expect(reopened.vehicle(vid).distance, old.distance + 1500);
    expect(
      await File(reopened.inspections.single.imagePath).readAsBytes(),
      bytes,
    );
    await reopened.db!.close();
  });

  test('손상·참조 오류·경로 공격 백업은 DB와 파일을 바꾸기 전에 거부한다', () async {
    final s = await createStore();
    addTearDown(() => s.db!.close());
    final dir = await Directory.systemTemp.createTemp('backup-invalid-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/valid.mbackup');
    await s.exportBackup(file);
    final original =
        jsonDecode(utf8.decode(gzip.decode(await file.readAsBytes()))) as Map;
    final broken = File('${dir.path}/broken.mbackup');
    await broken.writeAsBytes([1, 2, 3]);
    await expectLater(BackupSnapshot.read(broken), throwsA(isA<Exception>()));
    for (final kind in ['reference', 'duplicate', 'photoPath', 'date']) {
      final value = jsonDecode(jsonEncode(original)) as Map;
      if (kind == 'reference') {
        value['tables']['maintenance'][0]['vehicleId'] = 'UNKNOWN';
      }
      if (kind == 'duplicate') {
        value['tables']['vehicles'].add(value['tables']['vehicles'][0]);
      }
      if (kind == 'photoPath') value['photos']['../../escape'] = 'AA==';
      if (kind == 'date') value['created'] = 'x';
      final bad = File('${dir.path}/$kind.mbackup');
      await bad.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(value))));
      await expectLater(BackupSnapshot.read(bad), throwsFormatException);
    }
    final snapshot = await BackupSnapshot.read(file);
    snapshot.tables['maintenance']!.first['vehicleId'] = 'UNKNOWN';
    final count = s.records.length;
    await expectLater(
      s.restoreBackup(snapshot, Directory('${dir.path}/photos')),
      throwsFormatException,
    );
    expect(s.records.length, count);
    expect(await Directory('${dir.path}/photos').exists(), isFalse);
  });

  test('복원 중 DB 오류는 기존 기록과 사진을 보존하고 임시 사진을 정리한다', () async {
    final s = await createStore();
    addTearDown(() => s.db!.close());
    final dir = await Directory.systemTemp.createTemp('backup-rollback-');
    addTearDown(() => dir.delete(recursive: true));
    await s.saveQuestion('MOCK-RX-0001', '복원 시험 질문');
    final photo = File('${dir.path}/original.jpg');
    await photo.writeAsBytes([1, 2, 3]);
    await s.saveInspection(
      Inspection(
        id: 'ROLLBACK-PHOTO',
        vehicleId: 'MOCK-RX-0001',
        area: '가상',
        mode: '수동',
        created: '2026-10-09T12:00:00',
        imagePath: photo.path,
        note: '메모',
      ),
    );
    final file = File('${dir.path}/snapshot.mbackup');
    await s.exportBackup(file);
    final snapshot = await BackupSnapshot.read(file);
    final current = s.records.length;
    await s.db!.customStatement(
      "CREATE TRIGGER reject_restore BEFORE INSERT ON questions BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
    );
    final folder = Directory('${dir.path}/imported');
    await expectLater(
      s.restoreBackup(snapshot, folder),
      throwsA(isA<Exception>()),
    );
    expect(s.records.length, current);
    expect(
      (await s.db!.customSelect('SELECT id FROM maintenance').get()).length,
      current,
    );
    expect(await photo.readAsBytes(), [1, 2, 3]);
    expect(await folder.list().toList(), isEmpty);
    await s.db!.customStatement('DROP TRIGGER reject_restore');
    await s.db!.customStatement(
      "CREATE TRIGGER reject_prediction BEFORE INSERT ON predictions BEGIN SELECT RAISE(ABORT, 'prediction rollback'); END",
    );
    snapshot.tables['predictions']!.clear();
    final probability = s.predictions['MOCK-RX-0001']!['probability'];
    await expectLater(
      s.restoreBackup(snapshot, folder),
      throwsA(isA<Exception>()),
    );
    expect(
      (await s.db!.customSelect('SELECT id FROM maintenance').get()).length,
      current,
    );
    expect(s.predictions['MOCK-RX-0001']!['probability'], probability);
    expect(await folder.list().toList(), isEmpty);
    expect(await photo.exists(), isTrue);
  });
}
