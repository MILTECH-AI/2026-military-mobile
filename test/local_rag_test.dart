import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/adaptive_runtime.dart';
import 'package:military_maintenance/data/local_rag.dart';
import 'package:military_maintenance/data/model_execution.dart';
import 'package:military_maintenance/data/store.dart';

import 'knowledge_import_test.dart' show sample, fixtureVehicle;

class TestRuntime extends AdaptiveRuntime {
  TestRuntime(String path) {
    modelInfo = {
      'indexPath': path,
      'modelSha256': 'TEST-HASH',
      'executionConfig': 'TEST-CONFIG',
    };
  }
  int calls = 0;
  bool fail = false, wrongHash = false;
  @override
  Future<void> initialize() async {}
  @override
  Future<ModelRunResult> run(ModelTask task, Map<String, Object?> input) async {
    calls++;
    return fail
        ? const ModelRunResult('unavailable', reason: 'test_load_failure')
        : ModelRunResult(
            'model',
            output: {
              'modelSha256': wrongHash ? 'OTHER-HASH' : 'TEST-HASH',
              'executionConfig': 'TEST-CONFIG',
              'embedding': [1.0, ...List.filled(511, 0.0)],
            },
          );
  }
}

void main() {
  late Directory dir;
  late File indexFile;
  late AppStore s;
  late TestRuntime runtime;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rag-test-fixture-');
    indexFile = File('${dir.path}/index.json');
    s = sample();
    final e = s.supportLibrary.evidence.single;
    await indexFile.writeAsString(
      jsonEncode({
        'version': 1,
        'modelId': 'distiluse-int8-v1',
        'dimension': 512,
        'modelSha256': 'TEST-HASH',
        'executionConfig': 'TEST-CONFIG',
        'sourceEvidence': [e.toJson()],
        'chunks': [
          {
            'id': 'CHUNK',
            'evidenceId': e.id,
            'conceptId': e.conceptId,
            'text': e.text,
            'sourceRef': e.sourceRef,
            'charStart': 0,
            'charEnd': e.text.runes.length,
            'vector': [1.0, ...List.filled(511, 0.0)],
          },
        ],
      }),
    );
    runtime = TestRuntime(indexFile.path);
  });
  tearDown(() async {
    runtime.dispose();
    await dir.delete(recursive: true);
  });
  test('키워드가 일치하지 않아도 적용조건을 통과한 원문을 임베딩으로 검색한다', () async {
    const query = '키워드에 없는 질문';
    expect(s.searchEvidence(fixtureVehicle.id, '시험필터', query), isEmpty);
    final result = await LocalRag(runtime)
        .search(s, fixtureVehicle.id, '시험필터', query);
    expect(result.mode, 'hybrid');
    expect(result.evidence.single.id, s.supportLibrary.evidence.single.id);
    expect(runtime.calls, 1);
  });
  test('원문 조건 메타데이터가 등록 규칙과 다르면 모델 로드 전에 거부한다', () async {
    final index = jsonDecode(await indexFile.readAsString()) as Map;
    index['chunks'][0]['condition'] = {
      'kind': 'cycle_reference',
      'policies': ['severe'],
      'axes': ['period'],
    };
    await indexFile.writeAsString(jsonEncode(index));
    final r = await LocalRag(runtime)
        .search(s, fixtureVehicle.id, '시험필터', '시험용');
    expect(r.reason, 'condition_metadata_mismatch');
    expect(runtime.calls, 0);
  });
  test('모델 파일이 같아도 실행 설정이 다른 색인은 로드 전에 거부한다', () async {
    final index = jsonDecode(await indexFile.readAsString()) as Map;
    index['executionConfig'] = 'OTHER-CONFIG';
    await indexFile.writeAsString(jsonEncode(index));
    final result = await LocalRag(runtime)
        .search(s, fixtureVehicle.id, '시험필터', '시험용');
    expect(result.reason, 'index_execution_config_mismatch');
    expect(result.evidence, isNotEmpty);
    expect(runtime.calls, 0);
  });
  test('부품·차량 적용조건·기준시각 불일치는 임베딩 실행 전에 막는다', () async {
    final rag = LocalRag(runtime);
    expect(
      (await rag.search(s, fixtureVehicle.id, '다른부품', '원문')).evidence,
      isEmpty,
    );
    expect(
      (await rag.search(
        s,
        fixtureVehicle.id,
        '시험필터',
        '원문',
        asOf: DateTime(2024),
      )).evidence,
      isEmpty,
    );
    s.supportLibrary = s.supportLibrary.copyWith(rules: []);
    expect(
      (await rag.search(s, fixtureVehicle.id, '시험필터', '원문')).evidence,
      isEmpty,
    );
    expect(runtime.calls, 0);
  });
  test('모델 로드 실패·모델 색인 불일치·손상 색인은 기존 키워드 결과로 복귀한다', () async {
    final rag = LocalRag(runtime);
    runtime.fail = true;
    var r = await rag.search(s, fixtureVehicle.id, '시험필터', '시험용');
    expect(r.mode, 'keyword_fallback');
    expect(r.evidence, isNotEmpty);
    runtime.fail = false;
    runtime.wrongHash = true;
    r = await rag.search(s, fixtureVehicle.id, '시험필터', '시험용');
    expect(r.reason, 'model_index_changed');
    expect(r.evidence, isNotEmpty);
    await indexFile.writeAsString('{}');
    r = await rag.search(s, fixtureVehicle.id, '시험필터', '시험용');
    expect(r.mode, 'keyword_fallback');
    expect(r.evidence, isNotEmpty);
  });
  test('원문 내용 또는 적용 문서가 달라진 색인을 조용히 재사용하지 않는다', () async {
    final e = s.supportLibrary.evidence.single;
    final changed = MaintenanceEvidence.fromJson({
      ...e.toJson(),
      'text': '변경된 원문',
    });
    s.supportLibrary = s.supportLibrary.copyWith(evidence: [changed]);
    final r = await LocalRag(runtime)
        .search(s, fixtureVehicle.id, '시험필터', '변경된');
    expect(r.mode, 'keyword_fallback');
    expect(runtime.calls, 0);
    final wrongSource = MaintenanceEvidence.fromJson({
      ...e.toJson(),
      'sourceRef': {...e.sourceRef!, 'file': '다른차종.pdf'},
    });
    s.supportLibrary = s.supportLibrary.copyWith(evidence: [wrongSource]);
    expect(s.eligibleEvidence(fixtureVehicle.id, '시험필터'), isEmpty);
  });
}
