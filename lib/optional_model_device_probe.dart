import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/adaptive_runtime.dart';
import 'data/model_execution.dart';
import 'data/local_rag.dart';
import 'data/local_summary.dart';
import 'data/store.dart';

class ObservedModelWorker implements ModelWorker {
  final delegate = AndroidModelWorker();
  bool trimNextLlm = false;
  final loads = <Map<String, Object?>>[];
  String? trimCommandOutput;
  @override
  Future<void> load(String id, int threads) async {
    await delegate.load(id, threads);
    final probe = await AndroidModelWorker.channel
        .invokeMapMethod<String, Object?>('probe');
    loads.add({'modelId': id, ...?probe});
    if (trimNextLlm && id == 'qwen3-0.6b-q4_0') {
      trimNextLlm = false;
      trimCommandOutput = await const MethodChannel('maintenance/device_probe')
          .invokeMethod<String>('triggerTrim');
      // A trim signal alone may correctly keep running when RAM is sufficient.
      // Exercise the pressure branch explicitly with a debug-only RAM snapshot.
      await AndroidModelWorker.channel.invokeMethod<void>('diagnosticTrim', {
        'level': 15,
        'availableBytes': 0,
        'androidThresholdBytes': 268435456,
        'lowMemory': true,
      });
    }
  }

  @override
  Future<Map<String, Object?>> infer(Map<String, Object?> input) =>
      delegate.infer(input);
  @override
  Future<void> unload() => delegate.unload();
  @override
  Future<void> reset() => delegate.reset();
}

Future<void> runOptionalModelDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  final worker = ObservedModelWorker(), report = <String, Object?>{};
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
    };
    report['models'] = runtime.modelInfo['optionalModels'];
    if (!runtime.generationTrialAvailable || d.androidApi < 28) {
      throw StateError('optional generation is unavailable');
    }
    if (runtime.selectedTier != ModelTier.basic) {
      throw StateError('unmeasured automatic promotion');
    }
    store = AppStore(clock: () => DateTime(2026, 10, 31, 12));
    await store.initialize(database: LocalDatabase(NativeDatabase.memory()));
    const v = Vehicle(
      id: 'DEMO-LLM-001',
      model: '가상 렉스턴 2023 시험차',
      year: 2023,
      distance: 50000,
      hours: 1000,
      fuel: 3000,
      risk: 0,
    );
    await store.registerVehicle(v);
    final bundle = KnowledgeBundle.decode(
      await File(runtime.modelInfo['knowledgePath'] as String).readAsString(),
    );
    await store.importKnowledge(bundle);
    final t = store.supportLibrary.knowledge.templates.single;
    await store.updateSupportLibrary(
      (lib) => lib.copyWith(
        rules: [
          MaintenanceRule(
            id: 'DEMO-LLM-RULE',
            vehicleId: v.id,
            part: '오일필터',
            intervalKm: null,
            baselineKm: null,
            baselineDate: '',
            source: '시험용 적용조건 확인',
            conceptId: t['conceptId'] as String,
            templateId: t['id'] as String,
            applicabilityConfirmed: true,
            linkedAt: store!.clock().toIso8601String(),
          ),
        ],
      ),
    );
    const query = '오일필터를 분리할 때 주의할 점을 짧게 알려줘';
    final retrieval = await LocalRag(runtime)
        .search(store, v.id, '오일필터', query);
    if (retrieval.mode != 'hybrid' || retrieval.evidence.length < 2) {
      throw StateError('retrieval failed');
    }
    final evidence = retrieval.evidence.take(2).toList();
    report['retrievedEvidence'] = evidence
        .map((e) => {'id': e.id, 'sourceRef': e.sourceRef})
        .toList();
    final summary = await LocalSummary.summarize(
      runtime,
      query,
      evidence,
      maxTokens: 128,
    );
    if (summary.run?.mode != 'model') {
      throw StateError('real generation failed: ${summary.reason}');
    }
    if (summary.mode != 'extractive_summary' || summary.excerpts.isEmpty) {
      throw StateError('no accepted summary: ${summary.reason}');
    }
    if (summary.run!.output!['workerPid'] == pid) {
      throw StateError('process isolation failed');
    }
    report['generation'] = {
      'mode': summary.mode,
      'reason': summary.reason,
      'timingsMs': summary.run!.timingsMs,
      'rawOutput': summary.run!.output,
      'acceptedExcerpts': summary.excerpts
          .map((e) => {'id': e.citation, 'quote': e.quote})
          .toList(),
    };
    final unload = await AndroidModelWorker.channel
        .invokeMapMethod<String, Object?>('probe');
    if (unload?['loaded'] != false) throw StateError('unload failed');
    report['afterUnload'] = unload;
    final before = worker.loads.length;
    final cycle = await LocalSummary.summarize(
      runtime,
      '가혹 조건 교환 주기는 몇 개월인가요',
      evidence,
    );
    if (cycle.mode != 'retrieval_only' || worker.loads.length != before) {
      throw StateError('cycle rule isolation failed');
    }
    report['cycleBypassesLlm'] = true;
    final forged = LocalSummary.validate(
      '{"excerpts":[{"id":"${evidence.first.id}","quote":"교환하면 모든 고장을 예방할 수 있다."}]}',
      LocalSummary.sources(evidence),
    );
    if (forged.mode != 'retrieval_only') {
      throw StateError('citation gate failed');
    }
    report['unsupportedTextRejected'] = true;
    worker.trimNextLlm = true;
    final memory = await LocalSummary.summarize(
      runtime,
      query,
      evidence,
      maxTokens: 64,
    );
    if (memory.mode != 'retrieval_only' || !runtime.failedThisSession) {
      throw StateError('low-memory fallback failed');
    }
    report['memoryPressure'] = {
      'method': 'Android OS RUNNING_CRITICAL plus debug-injected low-RAM snapshot after real model load; not kernel OOM exhaustion',
      'commandOutput': worker.trimCommandOutput,
      'mode': memory.mode,
      'reason': memory.reason,
      'failedThisSession': runtime.failedThisSession,
    };
    final prior = worker.loads.length;
    final retry = await LocalSummary.summarize(runtime, query, evidence);
    if (retry.mode != 'retrieval_only' || worker.loads.length != prior) {
      throw StateError('failed session retried LLM');
    }
    report['failedSessionPreventsReload'] = true;
    report['automaticTierAfterRequest'] = runtime.automaticTier.name;
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
