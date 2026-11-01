import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/rag_ranking.dart';
import 'package:military_maintenance/data/rag_comparison.dart';
import 'package:military_maintenance/data/store.dart';

import 'knowledge_import_test.dart' show sample;

void main() {
  const conditions = {
    'NORMAL': RagCondition({'normal'}, {'distance', 'period'}),
    'SEVERE': RagCondition({'severe'}, {'distance', 'period'}),
    'PROCEDURE': RagCondition({}, {}),
  };
  RagRanking rank(String query, {String choice = 'unselected'}) => rankRag(
    chunks: [
      {
        'id': 'N',
        'evidenceId': 'NORMAL',
        'vector': [1, 0],
      },
      {
        'id': 'S',
        'evidenceId': 'SEVERE',
        'vector': [.9, .1],
      },
      {
        'id': 'P',
        'evidenceId': 'PROCEDURE',
        'vector': [.5, .5],
      },
    ],
    vector: [1, 0],
    keywordIds: ['NORMAL', 'SEVERE', 'PROCEDURE'],
    conditions: conditions,
    intent: RagIntent.parse(query, choice),
  );
  test('가혹 기간 질문은 일반 벡터 점수가 높아도 가혹 원문을 우선한다', () {
    final r = rank('가혹 조건에서 몇 개월마다 교환하나요', choice: 'normal');
    expect(r.semanticIds.first, 'NORMAL');
    expect(r.hybridIds.first, 'SEVERE');
    expect(r.intent.axes, {'period'});
    expect(r.intent.source, 'question');
  });
  test('질문 조건·부대 설정·미선택·부정 표현을 구분한다', () {
    expect(rank('일반 거리 기준', choice: 'severe').hybridIds.first, 'NORMAL');
    expect(rank('교환 주기', choice: 'severe').hybridIds.first, 'SEVERE');
    expect(rank('교환 주기').intent.policy, 'unselected');
    expect(rank('일반과 가혹의 거리 기간 비교').intent.policy, 'both');
    expect(rank('일반과 가혹의 거리 기간 비교').intent.axes, {'distance', 'period'});
    expect(rank('일반이 아닌 조건').intent.policy, 'ambiguous');
  });
  test('부대 기준이 선택되어도 절차 질문은 절차 원문을 우선한다', () {
    expect(rank('오일필터 분리 절차', choice: 'severe').hybridIds.first, 'PROCEDURE');
  });
  test('거리·기간 메타데이터는 해당 축을 포함한 조각을 우선한다', () {
    final r = rankRag(
      chunks: const [],
      vector: const [],
      keywordIds: ['DISTANCE', 'PERIOD'],
      conditions: const {
        'DISTANCE': RagCondition({'normal'}, {'distance'}),
        'PERIOD': RagCondition({'normal'}, {'period'}),
      },
      intent: RagIntent.parse('일반 몇 개월', 'unselected'),
    );
    expect(r.hybridIds.first, 'PERIOD');
  });
  test('검색 질문·인용문 숫자는 선택 규칙의 적용 수치를 변경하지 않는다', () {
    final s = sample();
    final rule = s.supportLibrary.rules.single;
    final before = s.selectedRuleCriteria(rule);
    rank('가혹 99999km 99개월', choice: 'normal');
    final e = s.supportLibrary.evidence.single;
    s.supportLibrary = s.supportLibrary.copyWith(
      evidence: [
        MaintenanceEvidence.fromJson({...e.toJson(), 'text': '99999km 99개월'}),
      ],
    );
    expect(s.selectedRuleCriteria(rule), before);
    expect(before['km'], 1000);
    expect(before['months'], 12);
    final unselected = sample(choice: 'unselected');
    final c = unselected.selectedRuleCriteria(
      unselected.supportLibrary.rules.single,
    );
    expect(c.containsKey('km'), isFalse);
    expect(c.containsKey('months'), isFalse);
    expect(c['reason'], '부대 적용 기준 미선택');
  });
  test('코사인 값과 순위 비교는 원소 오차와 별개로 판정한다', () {
    expect(vectorCosine([1, 0], [2, 0]), 1);
    final r = rank('주기');
    final pc = {
      'chunks': r.chunkIds,
      'semantic': r.semanticIds,
      'hybrid': r.hybridIds,
      'semanticScores': r.semanticScores,
    };
    expect(compareRagRanks(pc, r)['evidenceRanksEqual'], isTrue);
    expect(
      compareRagRanks({
        ...pc,
        'semantic': r.semanticIds.reversed.toList(),
      }, r)['evidenceRanksEqual'],
      isFalse,
    );
  });
}
