import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/adaptive_runtime.dart';
import 'data/local_rag.dart';
import 'data/model_execution.dart';
import 'data/store.dart';
import 'data/rag_ranking.dart';
import 'data/rag_comparison.dart';

/// Keeps only native operation/error codes; request payload and error messages stay in memory.
class RagDiagnosticWorker extends AndroidModelWorker {
  final failures = <Map<String, String>>[];
  @override
  Future<void> load(String modelId, int threads) async {
    try {
      await super.load(modelId, threads);
    } on PlatformException catch (e) {
      failures.add({'operation': 'load', 'code': e.code});
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>> infer(Map<String, Object?> input) async {
    try {
      return await super.infer(input);
    } on PlatformException catch (e) {
      failures.add({'operation': 'infer', 'code': e.code});
      rethrow;
    }
  }
}

/// Invoked only by the local androidTest instrumentation, with fake vehicle IDs.
Future<void> runRagDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  const reportChannel = MethodChannel('maintenance/device_probe');
  final config =
      await reportChannel.invokeMapMethod<String, Object?>('config') ?? {};
  final worker = RagDiagnosticWorker();
  final runtime = AdaptiveRuntime(
    worker: worker,
    threads: (config['threads'] as int?) ?? 2,
  );
  AppStore? store;
  final report = <String, Object?>{};
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
    final index = File(runtime.modelInfo['indexPath'] as String);
    final appFiles = index.parent.parent.parent;
    final probes = jsonDecode(
      await File('${appFiles.path}/rag-probes.json').readAsString(),
    ) as List;
    var maxError = 0.0;
    final timings = <Map<String, double>>[];
    final workerPids = <int>{};
    final pss = <num>[];
    final parityCases = <Map<String, Object?>>[];
    final actualVectors = <List<num>>[];
    report['parityCases'] = parityCases;
    for (final p in probes) {
      final result = await runtime.run(ModelTask.embedding, {
        'text': p['text'],
        'diagnostic': true,
      });
      if (result.mode != 'model') {
        throw StateError('embedding failed: ${result.reason}');
      }
      final output = result.output!;
      if (jsonEncode(output['tokenIds']) != jsonEncode(p['ids'])) {
        throw StateError('tokenizer parity mismatch');
      }
      final actual = (output['embedding'] as List).cast<num>();
      actualVectors.add(actual);
      final expected = (p['embedding'] as List).cast<num>();
      double caseError = 0, dot = 0, actualNorm = 0, expectedNorm = 0;
      for (var i = 0; i < actual.length; i++) {
        caseError = math.max(
          caseError,
          (actual[i] - expected[i]).abs().toDouble(),
        );
        dot += actual[i] * expected[i];
        actualNorm += actual[i] * actual[i];
        expectedNorm += expected[i] * expected[i];
        maxError = math.max(
          maxError,
          (actual[i] - expected[i]).abs().toDouble(),
        );
      }
      parityCases.add({
        'case': parityCases.length + 1,
        'inputTokens': (output['tokenIds'] as List).length,
        'maxAbsError': caseError,
        'cosine': dot / math.sqrt(actualNorm * expectedNorm),
      });
      workerPids.add(output['workerPid'] as int);
      pss.add(output['pssKb'] as num);
      timings.add(result.timingsMs!);
    }
    report['tokenizerParityCases'] = probes.length;
    report['embeddingMaxAbsErrorVsPc'] = maxError;
    report['phaseTimingsMs'] = timings;
    report['workerPssKbAfterInferenceSamples'] = pss;
    report['workerPids'] = workerPids.toList();
    report['uiPid'] = pid;
    report['acceptanceCriterion'] =
        'exact_token_ids_and_ordered_evidence_top_1_3_5_semantic_and_hybrid';
    report['elementwiseErrorRole'] = 'diagnostic_only';
    if (workerPids.contains(pid)) {
      throw StateError('process separation failed');
    }
    final unloaded = await AndroidModelWorker.channel
        .invokeMapMethod<String, Object?>('probe');
    if (unloaded?['loaded'] != false) {
      throw StateError('model was not unloaded');
    }
    report['unloadConfirmed'] = true;
    report['workerPssKbAfterUnload'] = unloaded?['pssKb'];
    store = AppStore(clock: () => DateTime(2026, 10, 31, 12));
    await store.initialize(database: LocalDatabase(NativeDatabase.memory()));
    const vehicle = Vehicle(
      id: 'DEMO-RAG-001',
      model: '가상 렉스턴 2023 시험차',
      year: 2023,
      distance: 50000,
      hours: 1000,
      fuel: 3000,
      risk: 0,
    );
    await store.registerVehicle(vehicle);
    final bundle = KnowledgeBundle.decode(
      await File(runtime.modelInfo['knowledgePath'] as String).readAsString(),
    );
    await store.importKnowledge(bundle);
    final rag = LocalRag(runtime);
    final blocked = await rag.search(store, vehicle.id, '오일필터', '필터 교환 주기');
    if (blocked.evidence.isNotEmpty || blocked.mode == 'hybrid') {
      throw StateError('applicability guard failed');
    }
    report['unconfirmedApplicabilityBlocked'] = true;
    final template = store.supportLibrary.knowledge.templates.single;
    await store.updateSupportLibrary(
      (lib) => lib.copyWith(
        rules: [
          MaintenanceRule(
            id: 'DEMO-RULE-001',
            vehicleId: vehicle.id,
            part: '오일필터',
            intervalKm: null,
            baselineKm: null,
            baselineDate: '',
            source: '시험용 적용조건 명시 확인',
            conceptId: template['conceptId'] as String,
            templateId: template['id'] as String,
            applicabilityConfirmed: true,
            linkedAt: store!.clock().toIso8601String(),
          ),
        ],
      ),
    );
    final pc = jsonDecode(
      await File('${appFiles.path}/rag-pc-rankings.json').readAsString(),
    ) as Map;
    final indexData = jsonDecode(await index.readAsString()) as Map;
    // Compare the full index, not only the model hash: a different corpus is not parity.
    if (jsonEncode(pc['index']) != jsonEncode(indexData) ||
        pc['modelSha256'] != runtime.modelInfo['modelSha256'] ||
        pc['executionConfig'] != runtime.modelInfo['executionConfig']) {
      throw StateError('PC comparison corpus/model/config mismatch');
    }
    final eligible = {
      for (final e in store.eligibleEvidence(vehicle.id, '오일필터')) e.id: e,
    };
    final rankCases = <Map<String, Object?>>[];
    var ranksEqual = true;
    for (final raw in pc['cases'] as List) {
      final c = raw as Map;
      final n = c['probeIndex'] as int;
      if (c['query'] != probes[n]['text']) {
        throw StateError('comparison input mismatch');
      }
      final ranking = rankRag(
        chunks: (indexData['chunks'] as List)
            .cast<Map>()
            .where((c) => eligible.containsKey(c['evidenceId']))
            .toList(),
        vector: actualVectors[n],
        keywordIds: store
            .searchEvidence(vehicle.id, '오일필터', c['query'] as String)
            .map((e) => e.id)
            .toList(),
        conditions: {
          for (final e in eligible.values)
            e.id: evidenceCondition(e, store.supportLibrary.knowledge),
        },
        intent: RagIntent.parse(
          c['query'] as String,
          c['selectedPolicy'] as String,
        ),
      );
      final comparison = compareRagRanks(c, ranking);
      ranksEqual = ranksEqual && comparison['evidenceRanksEqual'] == true;
      rankCases.add({
        'probeIndex': n,
        'query': c['query'],
        'selectedPolicy': c['selectedPolicy'],
        ...comparison,
      });
    }
    report['rankingCases'] = rankCases;
    report['orderedEvidenceRanksEqual'] = ranksEqual;
    final searches = <Map<String, Object?>>[];
    for (final query in [
      '오일필터 교환 주기',
      '오일 필터를 분리하는 절차',
      '가혹 조건에서 몇 개월마다 교환하나요',
    ]) {
      final watch = Stopwatch()..start();
      final result = await rag.search(store, vehicle.id, '오일필터', query);
      if (result.mode != 'hybrid' ||
          result.evidence.isEmpty ||
          result.evidence.length > 5) {
        throw StateError('hybrid retrieval failed: ${result.reason}');
      }
      searches.add({
        'query': query,
        'mode': result.mode,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
        'evidenceIds': result.evidence.map((e) => e.id).toList(),
      });
      if (query.startsWith('가혹') &&
          result.evidence.first.id != 'OIL-EVIDENCE-SEVERE') {
        throw StateError('severe reference priority regression');
      }
    }
    report['hybridSearches'] = searches;
    final wrongPart = await rag.search(store, vehicle.id, '브레이크패드', '오일필터');
    if (wrongPart.evidence.isNotEmpty) throw StateError('part guard failed');
    report['wrongPartBlocked'] = true;
    runtime.installedModels = [
      const ModelSpec(
        'injected-missing-model',
        ModelTask.embedding,
        ModelTier.basic,
        minAndroidApi: 24,
      ),
    ];
    final failure = await rag.search(store, vehicle.id, '오일필터', '오일필터 교환 주기');
    if (failure.mode != 'keyword_fallback' || failure.evidence.isEmpty) {
      throw StateError('load failure fallback failed');
    }
    report['nativeLoadFailureKeywordFallback'] = true;
    await runtime.refreshModels();
    final recovered = await rag.search(store, vehicle.id, '오일필터', '오일필터 교환 주기');
    if (recovered.mode != 'hybrid') throw StateError('worker recovery failed');
    report['workerRecovery'] = true;
    report['functionalStatus'] = 'passed';
    report['status'] = ranksEqual ? 'passed' : 'partial_rank_variation';
  } catch (e) {
    report['status'] = 'failed';
    report['error'] = '$e';
  } finally {
    report['nativeFailures'] = worker.failures;
    await runtime.manager.release();
    await store?.db?.close();
    runtime.dispose();
  }
  await reportChannel.invokeMethod<Object?>('complete', report);
}
