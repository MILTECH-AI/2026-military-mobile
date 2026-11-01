import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/adaptive_runtime.dart';
import 'data/local_rag.dart';
import 'data/local_summary.dart';
import 'data/store.dart';
import 'probe_fixture.dart';

/// Paired comparison with a shared, frozen retrieval prefix. Not an independent A/B trial.
Future<void> runRagUtilityDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('maintenance/device_probe');
  final config = await channel.invokeMapMethod<String, Object?>('config') ?? {};
  final runtime = AdaptiveRuntime(threads: (config['threads'] as int?) ?? 2);
  final report = <String, Object?>{
    'design': 'shared_retrieval_prefix',
    'cases': <Map<String, Object?>>[],
    'humanAdoption':
        'unmeasured; collect separately from automatic citation gate',
  };
  AppStore? store;
  try {
    await runtime.initialize();
    final d = runtime.device!;
    report['platform'] = d.isEmulator == true
        ? 'android-emulator'
        : 'android-device';
    report['physicalDevice'] = d.isEmulator == null ? null : !d.isEmulator!;
    report['threads'] = runtime.threads;
    report['api'] = d.androidApi;
    report['models'] = runtime.modelInfo;
    final files = File(runtime.modelInfo['indexPath'] as String)
        .parent
        .parent
        .parent;
    final packet = jsonDecode(
      await File('${files.path}/rag-utility-questions.json').readAsString(),
    ) as Map;
    final questions = (packet['questions'] as List).cast<Map>();
    if (questions.map((q) => q['id']).toSet().length != questions.length) {
      throw const FormatException('duplicate_question_id');
    }
    final ready = questions
        .where((q) => q['reviewedAgainstOriginal'] == true)
        .toList();
    report['questionCount'] = questions.length;
    report['reviewedCount'] = ready.length;
    if (ready.isEmpty) {
      report['evaluationStatus'] = 'awaiting_team_questions';
    } else {
      store = await oilProbeFixture(runtime, 'DEMO-UTILITY');
      // Validate the complete packet before executing any question.
      for (final q in ready) {
        validateUtilityQuestion(q, store.supportLibrary.evidence);
      }
      for (final q in ready) {
        await store.selectServicePolicy(q['selectedUnitPolicy'] as String);
        final before = jsonEncode(
          store.selectedRuleCriteria(store.supportLibrary.rules.single),
        );
        final watch = Stopwatch()..start();
        final retrieval = await LocalRag(runtime)
            .search(store, 'DEMO-UTILITY', '오일필터', q['question'] as String);
        final retrievalMs = watch.elapsedMicroseconds / 1000;
        // Same ordered evidence in both arms. Raw references remain visible in both.
        watch.reset();
        final summary = await LocalSummary.summarize(
          runtime,
          q['question'] as String,
          retrieval.evidence,
          maxTokens: 128,
        );
        final extraMs = watch.elapsedMicroseconds / 1000;
        final unchanged =
            before ==
            jsonEncode(
              store.selectedRuleCriteria(store.supportLibrary.rules.single),
            );
        if (!unchanged) throw StateError('rule_values_changed');
        (report['cases'] as List).add({
          'id': q['id'],
          'retrievedIds': retrieval.evidence.map((e) => e.id).toList(),
          'retrievedSources': [
            for (final e in retrieval.evidence)
              {'id': e.id, 'sourceRef': e.sourceRef},
          ],
          'retrievalMode': retrieval.mode,
          'retrievalReason': retrieval.reason,
          'retrievalOnlyMs': retrievalMs,
          'summaryExtraMs': extraMs,
          'withSummaryMs': retrievalMs + extraMs,
          'summaryMode': summary.mode,
          'summaryReason': summary.reason,
          'generationExecuted': summary.run?.mode == 'model',
          'automaticGateAccepted': summary.mode == 'extractive_summary',
          'summaryCitationIds': summary.excerpts
              .map((e) => e.citation)
              .toList(),
          'summaryExcerpts': [
            for (final e in summary.excerpts)
              {'id': e.citation, 'quote': e.quote},
          ],
          'embeddingTimingsMs': retrieval.timingsMs,
          'generationTimingsMs': summary.run?.timingsMs,
          'ruleValuesUnchanged': unchanged,
        });
      }
      report['evaluationStatus'] = 'measured';
    }
    report['status'] = 'passed';
  } catch (e) {
    report['status'] = 'failed';
    report['error'] = '$e';
  } finally {
    await runtime.manager.release();
    await store?.db?.close();
    runtime.dispose();
  }
  await channel.invokeMethod<Object?>('complete', report);
}

void validateUtilityQuestion(Map q, List<MaintenanceEvidence> catalog) {
  if ((q['id'] as String).trim().isEmpty ||
      (q['question'] as String).trim().isEmpty ||
      !['unselected', 'normal', 'severe'].contains(q['selectedUnitPolicy']) ||
      ![
        'rule_value',
        'evidence_reference',
        'clarification',
        'no_evidence',
      ].contains(q['expectedBehavior'])) {
    throw const FormatException('incomplete_reviewed_question');
  }
  final gold = (q['goldEvidence'] as List).cast<Map>();
  if (gold.isEmpty != (q['expectedBehavior'] == 'no_evidence')) {
    throw const FormatException('missing_gold_evidence');
  }
  for (final g in gold) {
    final e = catalog.where((e) => e.id == g['evidenceId']).firstOrNull;
    if (e == null ||
        e.sourceRef?['file'] != g['file'] ||
        e.sourceRef?['page'] != g['pdfPage']) {
      throw const FormatException('gold_source_mismatch');
    }
  }
  final ids = gold.map((g) => g['evidenceId']).toSet();
  if (!(q['mustRankFirst'] as List).every(ids.contains)) {
    throw const FormatException('must_rank_first_outside_gold');
  }
}
