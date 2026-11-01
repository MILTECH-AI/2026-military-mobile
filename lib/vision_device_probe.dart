import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/adaptive_runtime.dart';
import 'data/local_rag.dart';
import 'data/local_vision.dart';
import 'data/model_execution.dart';
import 'data/store.dart';
import 'optional_model_device_probe.dart' show ObservedModelWorker;

Future<void> runVisionDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{}, worker = ObservedModelWorker();
  final runtime = AdaptiveRuntime(worker: worker);
  AppStore? store;
  try {
    await runtime.initialize();
    final d = runtime.device!;
    report['platform'] = d.isEmulator == true
        ? 'android-emulator'
        : 'android-device';
    report['physicalDevice'] = d.isEmulator == null ? null : !d.isEmulator!;
    report['device'] = {
      'api': d.androidApi,
      'ramBytes': d.totalRamBytes,
      'cores': d.cores,
      'abis': d.abis,
      'cameraStatus': d.cameraStatus,
    };
    final appFiles = File(runtime.modelInfo['indexPath'] as String)
        .parent
        .parent
        .parent;
    final dog = '${appFiles.path}/../cache/vision-public-dog.png',
        empty = '${appFiles.path}/../cache/vision-public-empty.png';
    final production = await runtime.run(ModelTask.vision, {'imagePath': dog});
    if (d.cameraBlocked &&
        (production.mode != 'unavailable' || worker.loads.isNotEmpty)) {
      throw StateError('camera guard failed');
    }
    report['cameraGuardMode'] = production.mode;
    final results = <Map<String, Object?>>[];
    VisionAnalysis? detected;
    // Explicit adapter-only fixture test, independent of camera capture policy.
    for (final image in [empty, dog]) {
      final r = await runtime.manager.run(
        ModelTask.vision,
        runtime.installedModels,
        {'imagePath': image},
      );
      if (r.mode != 'model' || r.output?['workerPid'] == pid) {
        throw StateError('real Vision adapter/process isolation failed');
      }
      final a = VisionAnalysis.parse(r.output!);
      if (image == empty && a.detections.isNotEmpty) {
        throw StateError('empty image negative control failed');
      }
      if (image == dog && !a.detections.any((x) => x.classId == 18)) {
        throw StateError('public dog detection missing');
      }
      results.add({
        'input': image == empty ? 'public_black' : 'public_dog',
        'output': r.output,
        'timingsMs': r.timingsMs,
      });
      if (image == dog) detected = a;
      final probe = await AndroidModelWorker.channel
          .invokeMapMethod<String, Object?>('probe');
      if (probe?['loaded'] != false) throw StateError('Vision unload failed');
      report['afterVisionUnload'] = probe;
    }
    report['fixtureTests'] = results;
    store = AppStore(clock: () => DateTime(2026, 10, 31, 12));
    await store.initialize(database: LocalDatabase(NativeDatabase.memory()));
    const v = Vehicle(
      id: 'DEMO-VISION-001',
      model: '가상 렉스턴 2023 시험차',
      year: 2023,
      distance: 50000,
      hours: 1000,
      fuel: 3000,
      risk: 0,
    );
    await store.registerVehicle(v);
    await store.importKnowledge(
      KnowledgeBundle.decode(
        await File(runtime.modelInfo['knowledgePath'] as String).readAsString(),
      ),
    );
    final t = store.supportLibrary.knowledge.templates.single;
    await store.updateSupportLibrary(
      (lib) => lib.copyWith(
        rules: [
          MaintenanceRule(
            id: 'DEMO-VISION-RULE',
            vehicleId: v.id,
            part: '오일필터',
            intervalKm: null,
            baselineKm: null,
            baselineDate: '',
            source: '가상 적용조건 명시 확인',
            conceptId: t['conceptId'] as String,
            templateId: t['id'] as String,
            applicabilityConfirmed: true,
            linkedAt: store!.clock().toIso8601String(),
          ),
        ],
      ),
    );
    final candidates = visionConceptCandidates(
      detected!,
      store.supportLibrary.knowledge,
    );
    if (candidates.isNotEmpty) {
      throw StateError('unsupported COCO part mapping');
    }
    report['verifiedPartCandidates'] = 0;
    final imageRecord = Inspection(
      id: 'DEMO-VISION-PHOTO',
      vehicleId: v.id,
      area: '미지정',
      mode: '공개 모델 실행 시험',
      created: store.clock().toIso8601String(),
      imagePath: dog,
      note: '실차 부품 성능 평가 아님',
      vision: detected.toJson(),
    );
    await store.saveInspection(imageRecord);
    if (store.inspections.single.confirmedConceptId != null) {
      throw StateError('automatic concept confirmation');
    }
    // Simulates an explicit manual selection + confirmation, not a dog-to-part mapping.
    await store.saveInspection(
      store.inspections.single,
      confirmedConceptId: t['conceptId'] as String,
    );
    final confirmed = store.inspections.single;
    final retrieval = await LocalRag(runtime)
        .search(store, v.id, confirmed.area, '오일필터 교환 근거');
    if (retrieval.mode != 'hybrid' || retrieval.evidence.isEmpty) {
      throw StateError('confirmed part evidence lookup failed');
    }
    await store.addMaintenance(
      Maintenance(
        id: 'DEMO-VISION-MAINTENANCE',
        vehicleId: v.id,
        date: '2026-10-31',
        part: confirmed.area,
        system: '엔진/연료',
        description: '가상 수동 확인 흐름 시험',
        cost: 0,
        inspectionId: confirmed.id,
      ),
      confirmedConceptId: confirmed.confirmedConceptId,
    );
    final record = store.records.firstWhere(
      (r) => r.id == 'DEMO-VISION-MAINTENANCE',
    );
    if (record.confirmedConceptId != confirmed.confirmedConceptId ||
        record.inspectionId != confirmed.id ||
        record.replacementCompleted != null) {
      throw StateError('maintenance link failed');
    }
    report['manualConfirmedFlow'] = {
      'part': confirmed.area,
      'conceptId': confirmed.confirmedConceptId,
      'evidenceIds': retrieval.evidence.map((e) => e.id).toList(),
      'recordSaved': true,
      'replacementStatus': 'unknown',
    };
    report['limits'] = [
      'Public image adapter test; not camera hardware testing',
      'No reviewed COCO-to-part mapping',
      'No Rexton detection accuracy claim',
      'Manual confirmation is simulated by test calls; UI tested separately',
    ];
    report['status'] = 'passed';
  } catch (e) {
    report['status'] = 'failed';
    report['error'] = '$e';
  } finally {
    report['modelLoads'] = worker.loads;
    await runtime.manager.release();
    await store?.db?.close();
    runtime.dispose();
  }
  await const MethodChannel('maintenance/device_probe')
      .invokeMethod<Object?>('complete', report);
}
