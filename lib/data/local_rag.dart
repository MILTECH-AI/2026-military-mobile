import 'dart:convert';
import 'dart:io';

import 'rag_ranking.dart';

import 'adaptive_runtime.dart';
import 'model_execution.dart';
import 'store.dart';

class RagSearchResult {
  const RagSearchResult(
    this.evidence,
    this.mode, {
    this.reason,
    this.workerOutput,
    this.ranking,
    this.timingsMs,
  });
  final List<MaintenanceEvidence> evidence;
  final String mode;
  final String? reason;
  final Map<String, Object?>? workerOutput;
  final RagRanking? ranking;
  final Map<String, double>? timingsMs;
}

class LocalRag {
  LocalRag(this.runtime);
  final AdaptiveRuntime runtime;

  Future<RagSearchResult> search(
    AppStore store,
    String vehicle,
    String part,
    String query, {
    DateTime? asOf,
  }) async {
    final keyword = store.searchEvidence(vehicle, part, query, asOf: asOf);
    RagSearchResult fallback(String reason) {
      try {
        return RagSearchResult(
          rankedKeywordEvidence(store, vehicle, part, query, asOf: asOf),
          'keyword_fallback',
          reason: reason,
        );
      } catch (_) {
        return RagSearchResult(const [], 'keyword_fallback', reason: reason);
      }
    }

    try {
      await runtime.initialize();
      final path = runtime.modelInfo['indexPath'];
      final hash = runtime.modelInfo['modelSha256'];
      final config = runtime.modelInfo['executionConfig'];
      if (path is! String || hash is! String || query.trim().isEmpty) {
        return fallback('model_or_query_unavailable');
      }
      final file = File(path);
      if (await file.length() > 4 * 1024 * 1024) {
        return fallback('index_too_large');
      }
      final index = jsonDecode(await file.readAsString()) as Map;
      if (config is! String ||
          index['modelSha256'] != hash ||
          index['executionConfig'] != config) {
        return fallback('index_execution_config_mismatch');
      }
      if (index['version'] != 1 ||
          index['modelId'] != 'distiluse-int8-v1' ||
          index['dimension'] != 512) {
        return fallback('index_incompatible');
      }
      // Apply vehicle/part/time conditions before loading or ranking any vector.
      final libraryState = store.supportLibrary.encode();
      final eligible = {
        for (final e in store.eligibleEvidence(vehicle, part, asOf: asOf))
          e.id: e,
      };
      final sources = {
        for (final e in index['sourceEvidence'] as List)
          (e as Map)['id'] as String: e,
      };
      final chunks = <Map>[];
      for (final raw in index['chunks'] as List) {
        final c = raw as Map;
        final e = eligible[c['evidenceId']];
        final source = sources[c['evidenceId']];
        if (e == null || source == null) continue;
        if (e.text != source['text'] ||
            e.model != source['model'] ||
            e.part != source['part'] ||
            e.conceptId != source['conceptId'] ||
            e.conceptId != c['conceptId'] ||
            !['file', 'page', 'location', 'sha256'].every(
              (key) =>
                  e.sourceRef?[key] == source['sourceRef']?[key] &&
                  e.sourceRef?[key] == c['sourceRef']?[key],
            )) {
          continue;
        }
        final a = c['charStart'] as int, z = c['charEnd'] as int;
        // Python offsets count Unicode code points; Dart uses runes here too.
        if (a < 0 ||
            z <= a ||
            z > e.text.runes.length ||
            String.fromCharCodes(e.text.runes.toList().sublist(a, z)) !=
                c['text']) {
          continue;
        }
        final vector = (c['vector'] as List).cast<num>();
        if (c['condition'] != null) {
          final expected = evidenceCondition(
            e,
            store.supportLibrary.knowledge,
          ).toJson();
          final metadata = c['condition'] as Map;
          if (metadata['kind'] != expected['kind'] ||
              (List<String>.from(
                    metadata['policies'] as List,
                  )..sort()).join('|') !=
                  (expected['policies'] as List).join('|') ||
              (List<String>.from(metadata['axes'] as List)..sort()).join('|') !=
                  (expected['axes'] as List).join('|')) {
            return fallback('condition_metadata_mismatch');
          }
        }
        if (vector.length != 512 || vector.any((v) => !v.isFinite)) {
          return fallback('index_vector_invalid');
        }
        chunks.add(c);
      }
      if (chunks.isEmpty) return fallback('no_applicable_index');
      final result = await runtime.run(ModelTask.embedding, {'text': query});
      if (result.mode != 'model') {
        return fallback(result.reason ?? 'embedding_failed');
      }
      if (result.output?['modelSha256'] != hash ||
          result.output?['executionConfig'] != config) {
        return fallback('model_index_changed');
      }
      final vector = (result.output!['embedding'] as List).cast<num>();
      if (vector.length != 512 || vector.any((v) => !v.isFinite)) {
        return fallback('query_vector_invalid');
      }
      final ranking = rankRag(
        chunks: chunks,
        vector: vector,
        keywordIds: keyword
            .where((e) => eligible.containsKey(e.id))
            .map((e) => e.id)
            .toList(),
        conditions: {
          for (final e in eligible.values)
            e.id: evidenceCondition(e, store.supportLibrary.knowledge),
        },
        intent: RagIntent.parse(
          query,
          store.supportLibrary.knowledge.choiceAt(asOf ?? store.clock()),
        ),
      );
      if (libraryState != store.supportLibrary.encode()) {
        return fallback('context_changed');
      }
      return RagSearchResult(
        ranking.hybridIds.take(5).map((id) => eligible[id]!).toList(),
        'hybrid',
        workerOutput: result.output,
        ranking: ranking,
        timingsMs: result.timingsMs,
      );
    } catch (_) {
      return fallback('embedding_or_index_error');
    }
  }
}
