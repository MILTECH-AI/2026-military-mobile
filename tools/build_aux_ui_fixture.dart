// Fixture generation only. Not a UI or physical-model performance test.
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('generate isolated synthetic UI precondition through production backup APIs', () async {
    final store = AppStore(clock: () => DateTime(2026, 10, 31, 12));
    await store.initialize(database: LocalDatabase(NativeDatabase.memory()));
    if (!store.ready) throw StateError('fixture_store_not_ready');
    try {
      // Only this PC in-memory fixture DB is cleared; no device or original data is read.
      await store.db!.transaction(() async {
        for (final table in ['record_changes','predictions','questions','inspections','operations','maintenance','vehicles']) {
          await store.db!.customStatement('DELETE FROM $table');
        }
      });
      final knowledge = KnowledgeBundle.decode(await File(
        'private/tablet-test/oil-filter-tablet-reference.knowledge.json',
      ).readAsString());
      await store.registerVehicle(Vehicle(
        id: 'DEMO-NOTE20-AUX-001', model: knowledge.library.evidence.first.model,
        year: 2023, distance: 50000, hours: 1000, fuel: 3000, risk: 0,
      ));
      await store.importKnowledge(knowledge);
      final t = store.supportLibrary.knowledge.templates.single;
      await store.updateSupportLibrary((lib) => lib.copyWith(rules: [
        MaintenanceRule(
          id: 'DEMO-AUX-UI-RULE', vehicleId: 'DEMO-NOTE20-AUX-001', part: '오일필터',
          intervalKm: null, baselineKm: null, baselineDate: '',
          source: '가상 시험용 적용조건 선언 · 실차 검증 아님',
          conceptId: t['conceptId'] as String, templateId: t['id'] as String,
          applicabilityConfirmed: true, linkedAt: store.clock().toIso8601String(),
        ),
      ]));
      final file=File('private/note20-auxiliary/memory-policy-fix/NOTE20-AUX-UI-FIXTURE.mbackup');
      await store.exportBackup(file);
      final checked = await BackupSnapshot.read(file);
      if (checked.counts['vehicles']!=1 || checked.counts['maintenance']!=0 ||
          checked.tables['vehicles']!.single['id']!='DEMO-NOTE20-AUX-001') {
        throw StateError('fixture_scope_invalid');
      }
      await File('private/note20-auxiliary/memory-policy-fix/ui-fixture-validation.json').writeAsString(jsonEncode({
        'deviceAlias':'NOTE20-AUX-01','role':'태블릿 앱의 AI 실행 성능 측정용 보조 기기',
        'intendedAppFormFactor':'tablet','phoneLayoutFixesInScope':false,
        'syntheticVehicleCount':1,'actualVehicleIdentifiers':0,'maintenanceRecords':0,
        'evidenceCount':store.supportLibrary.evidence.length,
        'validatedByProductionBackupReader':true,'generationIsNotUiRegistrationProof':true,
        'applicabilityDeclarationForSyntheticFixtureOnly':true,
        'cyclePolicySelected':false,'rawQuestionsOrImagesLogged':false,
      }));
    } finally { await store.db?.close(); }
  });
}
