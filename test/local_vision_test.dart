import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/local_vision.dart';
import 'package:military_maintenance/data/store.dart';

import 'knowledge_import_test.dart' show bundleJson, fixtureVehicle;

Map<String, Object?> output() => {
  'modelId': 'ssd-mobilenet-int8-public-v1',
  'modelSha256':
      '2b79e6a7fb1ec6a33f332b9b10d82d9de4b7b49dcd26b5946921bb356895c954',
  'detections': [
    {
      'classId': 18,
      'score': .9,
      'box': [.1, .1, .9, .9],
    },
  ],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('공개 COCO 탐지 클래스는 근거 있는 부품 대응이 없으면 후보를 만들지 않는다', () {
    final b = KnowledgeBundle.decode(jsonEncode(bundleJson()));
    final a = VisionAnalysis.parse(output());
    expect(a.detections.single.label, 'dog');
    expect(visionConceptCandidates(a, b.library.knowledge), isEmpty);
    final fixture = VisionAnalysis('fixture-detector', 'fixture-hash', [
      const VisionDetection(1, .9, [0, 0, 1, 1]),
    ]);
    expect(
      visionConceptCandidates(
        fixture,
        b.library.knowledge,
        links: [
          const ReviewedVisionLink(
            'fixture-detector',
            1,
            'FILTER',
            '가상 대응 검토 근거',
          ),
        ],
      ).single['id'],
      'FILTER',
    );
    expect(
      visionConceptCandidates(
        fixture,
        b.library.knowledge,
        links: [const ReviewedVisionLink('fixture-detector', 1, 'FILTER', '')],
      ),
      isEmpty,
    );
  });
  test('손상된 모델 ID·박스·비수치·임계 미달 탐지를 거부한다', () {
    for (final bad in [
      {...output(), 'modelId': 'other'},
      {
        ...output(),
        'detections': [
          {
            'classId': 18,
            'score': double.nan,
            'box': [0, 0, 1, 1],
          },
        ],
      },
      {
        ...output(),
        'detections': [
          {
            'classId': 18,
            'score': .4,
            'box': [0, 0, 1, 1],
          },
        ],
      },
      {
        ...output(),
        'detections': [
          {
            'classId': 18,
            'score': .9,
            'box': [1, 0, 0, 1],
          },
        ],
      },
    ]) {
      expect(() => VisionAnalysis.parse(bad), throwsA(isA<Exception>()));
    }
  });
  test('탐지 결과·위조 DTO는 개념을 확정하지 않고 명시 확인만 저장한다', () async {
    final s = AppStore(clock: () => DateTime(2026, 10, 31, 12));
    await s.initialize(database: LocalDatabase(NativeDatabase.memory()));
    addTearDown(() => s.db!.close());
    await s.registerVehicle(fixtureVehicle);
    await s.importKnowledge(KnowledgeBundle.decode(jsonEncode(bundleJson())));
    const i = Inspection(
      id: 'DEMO-VISION',
      vehicleId: 'RULE-TEST-1',
      area: '미지정',
      mode: '가상 시험',
      created: '2026-10-31T12:00:00',
      imagePath: 'fixture-image.png',
      note: '가상 입력',
      conceptId: 'FILTER',
      conceptConfirmedAt: '2026-10-31T12:00:00',
    );
    await s.saveInspection(i);
    expect(s.inspections.single.confirmedConceptId, isNull);
    final a = VisionAnalysis.parse(output());
    await s.saveInspection(
      Inspection.fromJson({...i.toJson(), 'vision': a.toJson()}),
    );
    expect(s.inspections.single.confirmedConceptId, isNull);
    await s.saveInspection(s.inspections.single, confirmedConceptId: 'FILTER');
    expect(s.inspections.single.confirmedConceptId, 'FILTER');
    expect(s.inspections.single.area, '시험필터');
    final confirmed = s.inspections.single;
    await s.saveInspection(
      Inspection.fromJson({...confirmed.toJson(), 'note': '메모 수정'}),
    );
    expect(
      s.inspections.single.conceptConfirmedAt,
      confirmed.conceptConfirmedAt,
    );
    final directory = await Directory.systemTemp.createTemp(
      'vision-backup-fixture-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final photo = File('${directory.path}/photo.png');
    await photo.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      ),
    );
    await s.saveInspection(
      Inspection.fromJson({...confirmed.toJson(), 'imagePath': photo.path}),
      confirmedConceptId: null,
    );
    expect(s.inspections.single.vision, isNull);
    await s.saveInspection(
      Inspection.fromJson({
        ...s.inspections.single.toJson(),
        'vision': a.toJson(),
      }),
    );
    await s.saveInspection(s.inspections.single, confirmedConceptId: 'FILTER');
    final backup = File('${directory.path}/snapshot.mbackup');
    await s.exportBackup(backup);
    final snapshot = await BackupSnapshot.read(backup);
    await s.restoreBackup(snapshot, Directory('${directory.path}/restored'));
    expect(s.inspections.single.confirmedConceptId, 'FILTER');
    expect(
      s.inspections.single.vision?['modelId'],
      'ssd-mobilenet-int8-public-v1',
    );
    await s.saveInspection(
      Inspection.fromJson({
        ...confirmed.toJson(),
        'imagePath': 'different.png',
      }),
    );
    expect(s.inspections.single.confirmedConceptId, isNull);
  });
}
