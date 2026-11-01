import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';

Map<String, dynamic> source() => {
  'file': '가상지침.pdf',
  'page': 1,
  'sha256': 'a' * 64,
  'location': '가상 시험 절',
};
Map<String, dynamic> bundleJson() => {
  'format': 'maintenance-knowledge',
  'version': 1,
  'id': 'FIXTURE-BUNDLE',
  'evidence': [
    {
      'id': 'FIXTURE-E',
      'model': '가상 시험차',
      'part': '시험필터',
      'symptoms': '',
      'title': '가상 지침',
      'location': 'PDF 1쪽',
      'text': '시험용 원문',
      'conceptId': 'FILTER',
      'sourceRef': source(),
    },
  ],
  'knowledge': {
    'concepts': [
      {
        'id': 'FILTER',
        'name': '시험필터',
        'aliases': ['fixture_filter'],
      },
    ],
    'skus': [
      {
        'id': 'SKU',
        'conceptId': 'FILTER',
        'partNumber': '000A123456',
        'name': '가상 필터',
        'conditions': '실차 적용 미확인',
        'applicability': 'unconfirmed',
        'sourceRef': source(),
      },
    ],
    'templates': [
      {
        'id': 'CYCLE',
        'conceptId': 'FILTER',
        'requiresClarification': false,
        'applicabilityNote': '가상 사양 확인 필요',
        'normal': {
          'km': 1000,
          'months': 12,
          'note': '가상 일반 기준',
          'sourceRef': source(),
        },
        'severe': {
          'km': 500,
          'months': 6,
          'note': '가상 가혹 기준',
          'sourceRef': {...source(), 'file': '가상가혹지침.pdf', 'page': 2},
        },
      },
    ],
    'pending': [
      {
        'record': {
          'id': 'PENDING',
          'vehicleId': 'SRC-UNVERIFIED-1',
          'date': '2025-01-01',
          'part': '시험필터',
          'conceptId': 'FILTER',
          'system': '엔진/연료',
          'description': '가상 출처 미확인 기록',
          'cost': 0,
        },
        'verification': 'unverified',
        'sourceRef': source(),
      },
    ],
  },
};

const fixtureVehicle = Vehicle(
  id: 'RULE-TEST-1',
  model: '가상 시험차',
  year: 2020,
  distance: 2500,
  hours: 100,
  fuel: 100,
  risk: 0,
);
MaintenanceRule fixtureRule({
  int? km = 1000,
  String date = '2025-01-01',
  bool confirmed = true,
}) => MaintenanceRule(
  id: 'RULE',
  vehicleId: fixtureVehicle.id,
  part: '시험필터',
  intervalKm: null,
  baselineKm: km,
  baselineDate: date,
  source: '가상지침',
  conceptId: 'FILTER',
  templateId: 'CYCLE',
  applicabilityConfirmed: confirmed,
  linkedAt: '2025-01-01T00:00:00',
  baselineConfirmedAt: '2025-01-01T00:00:00',
);
AppStore sample({
  String choice = 'normal',
  int distance = 1500,
  String observation = '2026-10-01T00:00:00',
}) {
  final b = KnowledgeBundle.decode(jsonEncode(bundleJson()));
  return AppStore(clock: () => DateTime(2026, 10, 9))
    ..vehicles = [fixtureVehicle]
    ..supportLibrary = b.library.copyWith(
      rules: [fixtureRule()],
      knowledge: b.library.knowledge.copyWith(
        policyHistory: [
          {'at': '2025-01-01T00:00:00', 'choice': choice},
        ],
      ),
    )
    ..operations = [
      {
        'id': 'OP',
        'vehicleId': fixtureVehicle.id,
        'created': observation,
        'distance': distance,
        'hours': 100,
        'fuel': 100,
      },
    ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('부품을 하우징으로 수정하면 이전 소모품 개념 연결이 남아 있지 않는다', () async {
    final s = AppStore(clock: () => DateTime(2026, 10, 9));
    await s.initialize(database: LocalDatabase(NativeDatabase.memory()));
    addTearDown(() => s.db!.close());
    await s.registerVehicle(fixtureVehicle);
    await s.importKnowledge(KnowledgeBundle.decode(jsonEncode(bundleJson())));
    const row = Maintenance(
      id: 'CONCEPT-EDIT',
      vehicleId: 'RULE-TEST-1',
      date: '2026-10-01',
      part: 'fixture_filter',
      system: '엔진/연료',
      description: '가상 입력',
      cost: 0,
    );
    await s.addMaintenance(row, confirmedConceptId: 'FILTER');
    final saved = s.records.singleWhere((r) => r.id == row.id);
    expect(saved.conceptId, 'FILTER');
    await s.editMaintenance(
      Maintenance.fromJson({...saved.toJson(), 'part': '시험필터 하우징'}),
    );
    expect(s.records.singleWhere((r) => r.id == row.id).conceptId, isNull);
    expect(s.relatedMaintenance(fixtureVehicle.id, '시험필터', ''), isEmpty);
  });
  test('과거 기준 조회는 이후 정비 수정·삭제와 운용 수정의 이전 값을 재구성한다', () async {
    var now = DateTime(2025, 10, 1, 12);
    final s = AppStore(clock: () => now);
    await s.initialize(database: LocalDatabase(NativeDatabase.memory()));
    addTearDown(() => s.db!.close());
    await s.registerVehicle(fixtureVehicle);
    await s.importKnowledge(KnowledgeBundle.decode(jsonEncode(bundleJson())));
    await s.selectServicePolicy('normal');
    await s.updateSupportLibrary((lib) => lib.copyWith(rules: [fixtureRule()]));
    Maintenance completion(int km) => Maintenance(
      id: 'TEMPORAL',
      vehicleId: fixtureVehicle.id,
      date: '2025-10-01',
      part: 'fixture_filter',
      system: '엔진/연료',
      description: '가상 교환',
      cost: 0,
      replacementCompleted: true,
      odometerKm: km,
    );
    await s.addMaintenance(completion(2000), confirmedConceptId: 'FILTER');
    final at = DateTime(2025, 11, 1);
    expect(s.serviceDistance(fixtureRule(), asOf: at).reason, contains('미래'));
    now = at;
    expect(s.serviceDistance(fixtureRule(), asOf: at).remainingKm, 500);
    now = DateTime(2026, 10, 9, 12);
    await s.editMaintenance(completion(2200));
    expect(s.serviceDistance(fixtureRule()).remainingKm, 700);
    expect(s.serviceDistance(fixtureRule(), asOf: at).remainingKm, 500);
    final op = s.operations.singleWhere(
      (o) => o['vehicleId'] == fixtureVehicle.id,
    );
    await s.editOperation(op['id'], 2600, 110, 110);
    expect(s.serviceDistance(fixtureRule(), asOf: at).remainingKm, 500);
    now = DateTime(2026, 11, 1, 12);
    await s.deleteMaintenance('TEMPORAL');
    expect(s.serviceDistance(fixtureRule(), asOf: at).remainingKm, 500);
  });
  test('반입 검증·동일 자료 중복 방지·ID 충돌·SQL 실패 롤백', () async {
    final s = AppStore(clock: () => DateTime(2026, 10, 9));
    await s.initialize(database: LocalDatabase(NativeDatabase.memory()));
    addTearDown(() => s.db!.close());
    final before = s.records.length;
    final b = KnowledgeBundle.decode(jsonEncode(bundleJson()));
    expect(await s.importKnowledge(b), isTrue);
    expect(await s.importKnowledge(b), isFalse);
    expect(s.records.length, before);
    expect(
      s.supportLibrary.knowledge.pending.single['verification'],
      'unverified',
    );
    expect(s.supportLibrary.knowledge.skus.single['partNumber'], '000A123456');
    final changed = bundleJson();
    changed['evidence'][0]['text'] = '변경된 가상 원문';
    await expectLater(
      s.importKnowledge(KnowledgeBundle.decode(jsonEncode(changed))),
      throwsFormatException,
    );
    final empty = {
      'format': 'maintenance-knowledge',
      'version': 1,
      'id': 'OTHER',
      'evidence': [],
      'knowledge': {},
    };
    final saved = s.supportLibrary.encode();
    await s.db!.customStatement(
      "CREATE TRIGGER fail_import BEFORE INSERT ON app_metadata WHEN NEW.key='maintenance_support' BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END",
    );
    await expectLater(
      s.importKnowledge(KnowledgeBundle.decode(jsonEncode(empty))),
      throwsA(isA<Exception>()),
    );
    expect(s.supportLibrary.encode(), saved);
    final row = await s.db!
        .customSelect(
          "SELECT value FROM app_metadata WHERE key='maintenance_support'",
        )
        .getSingle();
    expect(row.read<String>('value'), saved);
  });
  test('잘못된 근거·참조·품번 타입·미확인 실적의 확정 상태를 거부한다', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (m) => m['knowledge']['skus'][0]['sourceRef']['page'] = 0,
      (m) => m['knowledge']['skus'][0]['partNumber'] = 123,
      (m) => m['knowledge']['skus'][0]['applicability'] = 'confirmed',
      (m) => m['knowledge']['skus'][0]['conceptId'] = 'MISSING',
      (m) =>
          m['knowledge']['pending'][0]['record']['replacementCompleted'] = true,
      (m) => m['knowledge']['concepts'].add({
        'id': 'OTHER',
        'name': '별도 부품',
        'aliases': ['fixture_filter'],
      }),
    ]) {
      final m = bundleJson();
      mutate(m);
      expect(
        () => KnowledgeBundle.decode(jsonEncode(m)),
        throwsFormatException,
      );
    }
  });
  test('일반·가혹 원문 기준은 보존되고 거리·기간·선도래를 독립 판정한다', () {
    final s = sample();
    final r = fixtureRule();
    var result = s.serviceDistance(r);
    expect(result.remainingKm, 500);
    expect(result.remainingDays, isNegative);
    expect(result.firstDue, '기간 기준 먼저 도래');
    s.operations.single['distance'] = 2200;
    result = s.serviceDistance(r);
    expect(result.remainingKm, 0);
    expect(result.firstDue, '둘 다 도래 · 선도래 순서 확인 불가');
    s.operations.single['created'] = '2025-11-01T00:00:00';
    result = s.serviceDistance(r, asOf: DateTime(2025, 12, 1));
    expect(result.remainingDays, isPositive);
    expect(result.firstDue, '거리 기준 먼저 도래');
    final k = s.supportLibrary.knowledge;
    s.operations = [
      {
        'id': 'EARLY',
        'vehicleId': fixtureVehicle.id,
        'created': '2025-12-01T00:00:00',
        'distance': 2100,
      },
      {
        'id': 'LATE',
        'vehicleId': fixtureVehicle.id,
        'created': '2026-10-01T00:00:00',
        'distance': 2200,
      },
    ];
    expect(s.serviceDistance(r).firstDue, '거리 기준 먼저 도래');
    s.operations = [
      {
        'id': 'BELOW',
        'vehicleId': fixtureVehicle.id,
        'created': '2026-01-02T00:00:00',
        'distance': 1500,
      },
      {
        'id': 'LATE',
        'vehicleId': fixtureVehicle.id,
        'created': '2026-10-01T00:00:00',
        'distance': 2200,
      },
    ];
    expect(s.serviceDistance(r).firstDue, '기간 기준 먼저 도래');
    s.supportLibrary = s.supportLibrary.copyWith(
      knowledge: k.copyWith(
        policyHistory: [
          ...k.policyHistory,
          {'at': '2026-10-01T00:00:00', 'choice': 'severe'},
        ],
      ),
    );
    expect(s.serviceDistance(r).policy, 'severe');
    expect(s.serviceDistance(r).sourceRef?['file'], '가상가혹지침.pdf');
    expect(s.serviceDistance(r, asOf: DateTime(2025, 12, 1)).policy, 'normal');
    expect(s.supportLibrary.knowledge.templates.single['normal']['km'], 1000);
    expect(s.supportLibrary.knowledge.templates.single['severe']['km'], 500);
  });
  test('오래된 거리 관측으로 기간 선도래를 추정하지 않으며 미확인 필드는 독립 보류한다', () {
    final s = sample(observation: '2025-11-01T00:00:00');
    expect(s.serviceDistance(fixtureRule()).firstDue, '선도래 순서 확인 불가');
    var result = s.serviceDistance(fixtureRule(km: null));
    expect(result.remainingKm, isNull);
    expect(result.calendarDue, isNotNull);
    result = s.serviceDistance(fixtureRule(date: ''));
    expect(result.remainingKm, 500);
    expect(result.calendarDue, isNull);
    expect(
      sample(choice: 'unselected').serviceDistance(fixtureRule()).reason,
      contains('선택'),
    );
    expect(
      s.serviceDistance(fixtureRule(confirmed: false)).reason,
      contains('적용조건'),
    );
    s.supportLibrary.knowledge.templates.single['requiresClarification'] = true;
    expect(s.serviceDistance(fixtureRule()).reason, contains('생산일·시행일'));
  });
  test('월말·윤년을 처리하고 미래 관측·늦게 입력한 기록은 과거 조회에 섞지 않는다', () {
    expect(addCalendarMonths(DateTime(2024, 1, 31), 1), DateTime(2024, 2, 29));
    expect(addCalendarMonths(DateTime(2025, 1, 31), 1), DateTime(2025, 2, 28));
    final s = sample();
    expect(
      s.serviceDistance(fixtureRule(), asOf: DateTime(2025, 12, 1)).remainingKm,
      isNull,
    );
    s.records = [
      const Maintenance(
        id: 'FUTURE-CAPTURE',
        vehicleId: 'RULE-TEST-1',
        date: '2025-11-01',
        part: 'fixture_filter',
        system: '엔진/연료',
        description: '늦게 입력한 가상 교환',
        cost: 0,
        replacementCompleted: true,
        odometerKm: 1400,
        createdAt: '2026-10-01T00:00:00',
        conceptId: 'FILTER',
        conceptConfirmedAt: '2026-10-01T00:00:00',
      ),
    ];
    s.operations.single['created'] = '2025-11-01T00:00:00';
    expect(
      s.serviceDistance(fixtureRule(), asOf: DateTime(2025, 12, 1)).baselineKm,
      1000,
    );
    expect(s.serviceDistance(fixtureRule()).baselineKm, 1400);
    expect(s.supportLibrary.knowledge.conceptFor('시험필터 하우징'), isNull);
    expect(s.supportLibrary.knowledge.conceptFor('FIXTURE-FILTER'), 'FILTER');
  });
  test('반입 자료·정책 이력·nullable 교환 기준은 재실행·백업 복원 후 보존된다', () async {
    final dir = await Directory.systemTemp.createTemp('knowledge-fixture-');
    addTearDown(() => dir.delete(recursive: true));
    final dbFile = File('${dir.path}/local.sqlite');
    var s = AppStore(clock: () => DateTime(2026, 10, 9));
    await s.initialize(database: LocalDatabase(NativeDatabase(dbFile)));
    await s.registerVehicle(fixtureVehicle);
    await s.importKnowledge(KnowledgeBundle.decode(jsonEncode(bundleJson())));
    await s.selectServicePolicy('normal');
    await s.selectServicePolicy('severe');
    expect(s.supportLibrary.knowledge.policyHistory.length, 2);
    expect(s.supportLibrary.knowledge.choiceAt(s.clock()), 'severe');
    await s.updateSupportLibrary(
      (lib) => lib.copyWith(rules: [fixtureRule(km: null, date: '')]),
    );
    final encoded = s.supportLibrary.encode();
    final backup = File('${dir.path}/test.mbackup');
    await s.exportBackup(backup);
    await s.db!.close();
    s = AppStore(clock: () => DateTime(2026, 10, 9));
    await s.initialize(database: LocalDatabase(NativeDatabase(dbFile)));
    addTearDown(() => s.db!.close());
    expect(s.supportLibrary.encode(), encoded);
    await s.saveSupportLibrary(const SupportLibrary());
    await s.restoreBackup(
      await BackupSnapshot.read(backup),
      Directory('${dir.path}/photos'),
    );
    expect(s.supportLibrary.encode(), encoded);
    expect(
      s.serviceDistance(s.supportLibrary.rules.single).remainingKm,
      isNull,
    );
  });
}
