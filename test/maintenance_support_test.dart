import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';

const vehicle = Vehicle(
  id: 'TEST-1',
  model: '시험차종',
  year: 2020,
  distance: 15000,
  hours: 300,
  fuel: 1000,
  risk: 0,
);
const rule = MaintenanceRule(
  id: 'RULE-1',
  vehicleId: 'TEST-1',
  part: '엔진오일',
  intervalKm: 10000,
  baselineKm: 10000,
  baselineDate: '2026-09-01',
  source: '시험 지침 1쪽',
);
const evidence = MaintenanceEvidence(
  id: 'DOC-1',
  model: '시험차종',
  part: '브레이크패드',
  symptoms: '제동 소음',
  title: '시험 문서',
  location: '2쪽 1절',
  text: '테스트용 원문 구간',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppStore sample() =>
      AppStore(clock: () => DateTime(2026, 10, 14))..vehicles = [vehicle];

  test('한영 부품 용어를 통일하고 차종과 부품 범위를 지켜 근거를 조회한다', () {
    expect(standardPart('brake_pad'), '브레이크패드');
    expect(standardPart('제동패드'), '브레이크패드');
    expect(partsIn('브레이크 패드 소음'), contains('브레이크패드'));
    final s = sample()
      ..supportLibrary = const SupportLibrary(
        evidence: [
          evidence,
          MaintenanceEvidence(
            id: 'OTHER',
            model: '다른차종',
            part: '브레이크패드',
            symptoms: '소음',
            title: '다른 지침',
            location: '1쪽',
            text: '다른 원문',
          ),
        ],
      );
    expect(s.searchEvidence(vehicle.id, '제동패드', '').single.id, 'DOC-1');
    expect(s.searchEvidence(vehicle.id, '', 'brake_pad').single.id, 'DOC-1');
    expect(s.searchEvidence(vehicle.id, '배터리', ''), isEmpty);
    expect(s.searchEvidence(vehicle.id, '', '없는증상'), isEmpty);
  });

  test('교환 계기에서 잔여 거리를 계산하며 최신 정비가 있으면 계산을 보류한다', () {
    final s = sample();
    expect(s.serviceDistance(rule).remainingKm, 5000);
    s.records = [
      const Maintenance(
        id: 'M1',
        vehicleId: 'TEST-1',
        date: '2026-10-01',
        part: 'engine_oil',
        system: '엔진/연료',
        description: '교환',
        cost: 0,
      ),
    ];
    expect(s.serviceDistance(rule).remainingKm, isNull);
    expect(s.serviceDistance(rule).reason, contains('갱신'));
    s.records = [];
    final due = MaintenanceRule(
      id: rule.id,
      vehicleId: rule.vehicleId,
      part: rule.part,
      intervalKm: 1000,
      baselineKm: 10000,
      baselineDate: rule.baselineDate,
      source: rule.source,
    );
    expect(s.serviceDistance(due).remainingKm, 0);
    expect(s.estimatedServiceDate(due), s.clock());
  });

  test('표준부품 10개와 동의어 24개를 대소문자·구분자와 무관하게 인식한다', () {
    const cases = {
      '엔진오일': ['engine_oil', '엔진 오일'],
      '오일필터': ['oil_filter', '오일 필터'],
      '에어필터': ['air_filter', '에어 필터', '흡기필터'],
      '연료필터': ['fuel_filter', '연료 필터'],
      '브레이크패드': ['brake_pad', 'brake pad', '브레이크 패드', '제동패드'],
      '브레이크호스': ['brake_hose', '브레이크 호스', '제동호스'],
      '타이어': ['tire', 'tyre'],
      '배터리': ['battery', '축전지'],
      '냉각수호스': ['coolant_hose', '냉각수 호스'],
      '전조등': ['headlight', '헤드라이트'],
    };
    expect(standardParts.length, 10);
    expect(standardParts.values.fold<int>(0, (n, v) => n + v.length), 24);
    for (final entry in cases.entries) {
      for (final input in [entry.key, ...entry.value]) {
        expect(standardPart(input), entry.key, reason: input);
        expect(
          standardPart('  ${input.toUpperCase().replaceAll('_', '-')}  '),
          entry.key,
          reason: '대소문자·구분자: $input',
        );
        expect(partsIn('$input 점검'), contains(entry.key));
      }
    }
    expect(standardPart('등록되지 않은 부품'), '등록되지 않은 부품');
  });

  test('근거 검색은 5개로 제한하고 점수 내림차순·동점 ID 순서를 유지한다', () {
    MaintenanceEvidence source(
      String id,
      String text, {
      String model = '시험차종',
      String part = '엔진오일',
    }) => MaintenanceEvidence(
      id: id,
      model: model,
      part: part,
      symptoms: '',
      title: '가상 검색 시험',
      location: '1쪽',
      text: text,
    );
    final docs = [
      source('G1', '소음'),
      source('E2', '소음 누유'),
      source('C3', '소음 누유 진동'),
      source('F1', '진동'),
      source('D2', '누유 진동'),
      source('B3', '소음 누유 진동'),
      source('A3', '소음 누유 진동'),
      source('X0', '일반 설명'),
      source('000-OTHER-MODEL', '소음 누유 진동', model: '다른차종'),
      source('000-OTHER-PART', '소음 누유 진동', part: '배터리'),
    ];
    final s = sample()..supportLibrary = SupportLibrary(evidence: docs);
    List<String> results() => s
        .searchEvidence(vehicle.id, 'engine_oil', '소음 누유 진동')
        .map((e) => e.id)
        .toList();
    expect(results(), ['A3', 'B3', 'C3', 'D2', 'E2']);
    s.supportLibrary = SupportLibrary(evidence: docs.reversed.toList());
    expect(results(), ['A3', 'B3', 'C3', 'D2', 'E2']);
    expect(s.searchEvidence(vehicle.id, '엔진오일', '없는증상'), isEmpty);
  });

  test('교환 기준일 당일의 미확인 정비는 순서를 추정하지 않고 보류한다', () {
    final s = sample();
    Maintenance unknown(String id, String date, {String part = 'engine_oil'}) =>
        Maintenance(
          id: id,
          vehicleId: vehicle.id,
          date: date,
          part: part,
          system: '엔진/연료',
          description: '가상 미확인 기록',
          cost: 0,
        );
    s.records = [unknown('SAME-DAY', rule.baselineDate)];
    expect(s.serviceDistance(rule).remainingKm, isNull);
    expect(s.serviceDistance(rule).reason, contains('작업 순서'));
    s.records = [unknown('OLDER', '2026-08-31')];
    expect(s.serviceDistance(rule).remainingKm, 5000);
    s.records = [unknown('OTHER-PART', rule.baselineDate, part: '배터리')];
    expect(s.serviceDistance(rule).remainingKm, 5000);
    const completion = Maintenance(
      id: 'DONE',
      vehicleId: 'TEST-1',
      date: '2026-10-01',
      part: '엔진오일',
      system: '엔진/연료',
      description: '가상 교환 완료',
      cost: 0,
      replacementCompleted: true,
      odometerKm: 14000,
    );
    final sameDay = unknown('UNKNOWN-ORDER', completion.date);
    for (final rows in [
      [completion, sameDay],
      [sameDay, completion],
    ]) {
      s.records = rows;
      expect(s.serviceDistance(rule).remainingKm, isNull);
    }
    s.records = [completion, unknown('BEFORE-COMPLETION', '2026-09-30')];
    expect(s.serviceDistance(rule).remainingKm, 9000);
  });

  test('운용 추세가 충분할 때만 다음 정비 날짜를 추정한다', () {
    final s = sample();
    Map<String, dynamic> op(String day, int km) => {
      'vehicleId': vehicle.id,
      'created': day,
      'distance': km,
    };
    expect(s.estimatedServiceDate(rule), isNull);
    s.operations = [op('2026-09-14', 12000), op('2026-10-14', 15000)];
    expect(s.estimatedServiceDate(rule), DateTime(2026, 12, 3));
    s.operations = [op('2026-09-14', 15000), op('2026-10-14', 15000)];
    expect(s.estimatedServiceDate(rule), isNull);
    s.operations = [op('2026-08-01', 12000), op('2026-09-01', 15000)];
    expect(s.estimatedServiceDate(rule), isNull);
    s.operations = [op('2026-10-11', 12000), op('2026-10-14', 15000)];
    expect(s.estimatedServiceDate(rule), isNull);
  });

  test('서머타임 전환을 포함한 7일 관측과 정비일은 달력 날짜로 계산한다', () {
    final s = AppStore(clock: () => DateTime(2026, 3, 12, 13))
      ..vehicles = [vehicle]
      ..operations = [
        {'vehicleId': vehicle.id, 'created': '2026-03-05', 'distance': 12000},
        {'vehicleId': vehicle.id, 'created': '2026-03-12', 'distance': 15000},
      ];
    const springRule = MaintenanceRule(
      id: 'SPRING',
      vehicleId: 'TEST-1',
      part: '엔진오일',
      intervalKm: 10000,
      baselineKm: 10000,
      baselineDate: '2026-01-01',
      source: '가상 지침',
    );
    expect(s.estimatedServiceDate(springRule), DateTime(2026, 3, 24));
  });

  test('근거 위치와 정비 주기의 범위·중복을 검증한다', () {
    expect(
      SupportLibrary.decode(
        const SupportLibrary(evidence: [evidence], rules: [rule]).encode(),
      ).rules.single.baselineKm,
      10000,
    );
    expect(
      () => SupportLibrary.decode(
        const SupportLibrary(rules: [rule, rule]).encode(),
      ),
      throwsFormatException,
    );
    const invalid = MaintenanceRule(
      id: 'bad',
      vehicleId: 'TEST-1',
      part: '엔진오일',
      intervalKm: 0,
      baselineKm: 0,
      baselineDate: '2026-02-30',
      source: '지침',
    );
    expect(
      () => SupportLibrary.decode(
        const SupportLibrary(rules: [invalid]).encode(),
      ),
      throwsFormatException,
    );
    const missingSource = MaintenanceEvidence(
      id: 'x',
      model: '시험차종',
      part: '엔진오일',
      symptoms: '',
      title: '지침',
      location: '',
      text: '본문',
    );
    expect(
      () => SupportLibrary.decode(
        const SupportLibrary(evidence: [missingSource]).encode(),
      ),
      throwsFormatException,
    );
  });

  test('근거와 정비 주기를 재시작·백업·복원 후에도 보존한다', () async {
    final folder = await Directory.systemTemp.createTemp('support-test-');
    final file = File('${folder.path}/db.sqlite');
    final s = AppStore(clock: () => DateTime(2026, 10, 14));
    await s.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(s.error, isNull);
    final v = s.vehicles.first;
    final r = MaintenanceRule(
      id: 'RULE-LOCAL',
      vehicleId: v.id,
      part: '엔진오일',
      intervalKm: 10000,
      baselineKm: v.distance,
      baselineDate: '2026-10-14',
      source: '시험용 주기',
    );
    await s.saveSupportLibrary(
      SupportLibrary(evidence: const [evidence], rules: [r]),
    );
    await s.saveQuestion(v.id, '제동 소음', partName: 'brake_pad');
    await s.db!.close();
    final reopened = AppStore(clock: () => DateTime(2026, 10, 14));
    await reopened.initialize(database: LocalDatabase(NativeDatabase(file)));
    expect(reopened.supportLibrary.rules.single.id, r.id);
    expect(reopened.questions.single['standardPart'], '브레이크패드');
    final backup = File('${folder.path}/copy.mbackup');
    await reopened.exportBackup(backup);
    final snapshot = await BackupSnapshot.read(backup);
    await reopened.saveSupportLibrary(const SupportLibrary());
    await reopened.restoreBackup(snapshot, Directory('${folder.path}/photos'));
    expect(reopened.supportLibrary.evidence.single.location, '2쪽 1절');
    expect(reopened.supportLibrary.rules.single.vehicleId, v.id);
    expect(reopened.questions.single['standardPart'], '브레이크패드');
    expect(
      reopened
          .serviceDistance(reopened.supportLibrary.rules.single)
          .remainingKm,
      10000,
    );
    await reopened.db!.close();
    await folder.delete(recursive: true);
  });
}
