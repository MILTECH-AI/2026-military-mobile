import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/local_summary.dart';
import 'package:military_maintenance/data/adaptive_runtime.dart';

void main() {
  test('긴 질문은 조용히 자르거나 모델을 실행하지 않고 원문으로 전환한다', () async {
    final runtime = AdaptiveRuntime();
    final result = await LocalSummary.summarize(runtime, '가' * 121, const []);
    expect(result.mode, 'retrieval_only');
    expect(result.reason, 'question_exceeds_local_summary_budget');
    runtime.dispose();
  });
  const sources = {
    'E1': '엔진을 정지하고 충분히 냉각한 뒤 작업한다. 오일필터를 분리한다.',
    'E2': '오염물이 들어가지 않도록 막는다.',
  };
  String response(String id, String quote) => jsonEncode({
    'excerpts': [
      {'id': id, 'quote': quote},
    ],
  });
  test('줄바꿈만 정규화한 문장 후보를 만들고 숫자 머리글과 무응답을 처리한다', () {
    final context = {
      'E1': LocalSummary.canonical(
        r'가상 지침 2023.05\r\n필터를 분리한다. 확인 후 안전하게 조립한다.',
      ),
      'E2': '작업 후 누유를 점검한다.',
    };
    final allowed = LocalSummary.candidates(context);
    expect(allowed.map((s) => s.quote), contains('확인 후 안전하게 조립한다.'));
    expect(allowed.any((s) => LocalSummary.numeric.hasMatch(s.quote)), isFalse);
    expect(
      LocalSummary.validate(response('E1', '확인 후 안전하게 조립한다.'), context).mode,
      'extractive_summary',
    );
    expect(
      LocalSummary.validate('{"excerpts":[]}', context).reason,
      'no_supported_excerpt',
    );
  });
  test('출처에 있는 완전한 문장만 인용 요약으로 채택한다', () {
    final r = LocalSummary.validate(response('E1', '오일필터를 분리한다.'), sources);
    expect(r.mode, 'extractive_summary');
    expect(r.excerpts.single.citation, 'E1');
  });
  test('존재하는 인용 ID라도 근거 밖 설명·번역·부분 절은 거부한다', () {
    for (final pair in [
      ('E1', '필터 교환으로 고장이 예방된다.'),
      ('E1', '충분히 냉각한 뒤 작업한다.'),
      ('E3', '오일필터를 분리한다.'),
    ]) {
      expect(
        LocalSummary.validate(response(pair.$1, pair.$2), sources).mode,
        'retrieval_only',
      );
    }
    expect(
      LocalSummary.validate(
        response('E1', '엔진을 정지하고 충분히 냉각한 뒤 작업한다.'),
        sources,
      ).mode,
      'extractive_summary',
    );
  });
  test('출처에 있어도 숫자·교환 기간 수치는 요약에서 채택하지 않는다', () {
    for (final quote in ['매 1000km마다 교환한다.', '매 육 개월마다 교환한다.']) {
      expect(
        LocalSummary.validate(response('E1', quote), {
          'E1': quote,
          'E2': sources['E2']!,
        }).reason,
        'numeric_statement',
      );
    }
    expect(LocalSummary.cycleQuestion.hasMatch('가혹 교환 주기는?'), isTrue);
  });
  test('형식 손상·추가 자유 설명·중복·너무 긴 문장은 원문으로 전환한다', () {
    for (final raw in [
      '요약입니다.',
      '{"excerpts":[]}',
      jsonEncode({
        'excerpts': [
          {'id': 'E1', 'quote': '오일필터를 분리한다.'},
        ],
        'answer': '자유 설명',
      }),
    ]) {
      expect(LocalSummary.validate(raw, sources).mode, 'retrieval_only');
    }
    expect(LocalSummary.excerpt('가' * 400), isEmpty);
  });
}
