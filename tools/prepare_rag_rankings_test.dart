// Run after build_oil_embedding_bundle.py, with RAG_QA_DIR set to its parent.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/adaptive_runtime.dart';
import 'package:military_maintenance/data/rag_ranking.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/probe_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('동일 Dart 정렬기로 PC 벡터의 14입력·3조건 기준 순위를 기록한다', () async {
    final dir = Platform.environment['RAG_QA_DIR'] ?? 'private/qa-rag';
    final index =
        jsonDecode(File('$dir/bundle/index.json').readAsStringSync()) as Map;
    final probes =
        jsonDecode(File('$dir/parity-probes.json').readAsStringSync()) as List;
    final runtime = AdaptiveRuntime()
      ..modelInfo = {'knowledgePath': '$dir/bundle/knowledge.json'};
    final store = await oilProbeFixture(runtime, 'DEMO-RAG-PC');
    addTearDown(() async {
      await store.db!.close();
      runtime.dispose();
    });
    final eligible = {
      for (final e in store.eligibleEvidence('DEMO-RAG-PC', '오일필터')) e.id: e,
    };
    expect(eligible.length, 3);
    final cases = <Map<String, Object?>>[];
    for (var i = 0; i < probes.length; i++) {
      final probe = probes[i] as Map;
      for (final policy in ['unselected', 'normal', 'severe']) {
        final query = probe['text'] as String;
        final ranking = rankRag(
          chunks: (index['chunks'] as List).cast<Map>(),
          vector: (probe['embedding'] as List).cast<num>(),
          keywordIds: store
              .searchEvidence('DEMO-RAG-PC', '오일필터', query)
              .map((e) => e.id)
              .toList(),
          conditions: {
            for (final e in eligible.values)
              e.id: evidenceCondition(e, store.supportLibrary.knowledge),
          },
          intent: RagIntent.parse(query, policy),
        );
        cases.add({
          'probeIndex': i,
          'query': query,
          'selectedPolicy': policy,
          'chunks': ranking.chunkIds,
          'semantic': ranking.semanticIds,
          'hybrid': ranking.hybridIds,
          'semanticScores': ranking.semanticScores,
        });
      }
    }
    await File('$dir/pc-rankings.json').writeAsString(
      jsonEncode({
        'index': index,
        'modelSha256': index['modelSha256'],
        'executionConfig': index['executionConfig'],
        'cases': cases,
      }),
    );
    expect(cases.length, probes.length * 3);
  });
}
