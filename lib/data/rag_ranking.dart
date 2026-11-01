import 'dart:math' as math;

import 'store.dart';

class RagCondition {
  const RagCondition(this.policies, this.axes);
  final Set<String> policies, axes;
  bool get cycle => policies.isNotEmpty;
  String get label {
    if (!cycle) return '일반·가혹 조건 미지정 · 절차·기타 원문';
    final policy = policies.map((p) => p == 'normal' ? '일반' : '가혹').join('·');
    final axis = axes.map((a) => a == 'distance' ? '거리' : '기간').join('·');
    return '$policy · $axis';
  }

  Map<String, Object> toJson() => {
    'policies': policies.toList()..sort(),
    'axes': axes.toList()..sort(),
    'kind': cycle ? 'cycle_reference' : 'reference',
  };
}

RagCondition evidenceCondition(MaintenanceEvidence e, KnowledgeData knowledge) {
  final policies = <String>{}, axes = <String>{};
  for (final template in knowledge.templates) {
    if (template['conceptId'] != e.conceptId) continue;
    for (final policy in ['normal', 'severe']) {
      final p = template[policy] as Map;
      final source = p['sourceRef'] as Map;
      if ([
        'file',
        'page',
        'sha256',
        'location',
      ].every((k) => source[k] == e.sourceRef?[k])) {
        policies.add(policy);
        if (p['km'] != null) axes.add('distance');
        if (p['months'] != null) axes.add('period');
      }
    }
  }
  return RagCondition(policies, axes);
}

class RagIntent {
  const RagIntent(
    this.policy,
    this.source,
    this.axes,
    this.procedure,
    this.cycle,
  );
  final String policy, source;
  final Set<String> axes;
  final bool procedure, cycle;
  factory RagIntent.parse(String query, String selectedPolicy) {
    final q = query.toLowerCase();
    final normal = q.contains('일반'), severe = q.contains('가혹');
    final negation = RegExp('아닌|아니라|제외|말고').hasMatch(q);
    final explicit = normal || severe;
    final policy = explicit
        ? negation
              ? 'ambiguous'
              : normal && severe
              ? 'both'
              : normal
              ? 'normal'
              : 'severe'
        : ['normal', 'severe'].contains(selectedPolicy)
        ? selectedPolicy
        : 'unselected';
    final axes = <String>{};
    if (RegExp(r'거리|주행|km|킬로|키로').hasMatch(q)) axes.add('distance');
    if (RegExp(r'기간|개월|몇\s*달|몇달|날짜').hasMatch(q)) axes.add('period');
    final procedure = RegExp('절차|방법|탈거|분리|장착|토크|토오크|오.?링|주의').hasMatch(q);
    final cycle =
        !procedure &&
        (explicit || axes.isNotEmpty || RegExp('주기|언제|기준|교환하나').hasMatch(q));
    return RagIntent(
      policy,
      explicit ? 'question' : 'unit_selection',
      axes,
      procedure,
      cycle,
    );
  }
  Map<String, Object> toJson() => {
    'policy': policy,
    'source': source,
    'axes': axes.toList()..sort(),
    'procedure': procedure,
    'cycle': cycle,
  };
}

double vectorCosine(List<num> a, List<num> b) {
  if (a.length != b.length ||
      a.isEmpty ||
      a.any((v) => !v.isFinite) ||
      b.any((v) => !v.isFinite)) {
    throw const FormatException('invalid vector');
  }
  double dot = 0, aa = 0, bb = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  if (aa <= 0 || bb <= 0) throw const FormatException('zero vector');
  return dot / math.sqrt(aa * bb);
}

class RagRanking {
  const RagRanking(
    this.chunkIds,
    this.semanticIds,
    this.hybridIds,
    this.chunkScores,
    this.semanticScores,
    this.intent,
  );
  final List<String> chunkIds, semanticIds, hybridIds;
  final Map<String, double> chunkScores, semanticScores;
  final RagIntent intent;
}

RagRanking rankRag({
  required List<Map> chunks,
  required List<num> vector,
  required List<String> keywordIds,
  required Map<String, RagCondition> conditions,
  required RagIntent intent,
}) {
  final chunkScores = <String, double>{}, semantic = <String, double>{};
  for (final c in chunks) {
    final score = vectorCosine(vector, (c['vector'] as List).cast<num>());
    chunkScores[c['id'] as String] = score;
    final id = c['evidenceId'] as String;
    if (score > (semantic[id] ?? -2)) semantic[id] = score;
  }
  List<String> byScore(Map<String, double> scores) =>
      scores.keys.toList()..sort((a, b) {
        final compare = scores[b]!.compareTo(scores[a]!);
        return compare != 0 ? compare : a.compareTo(b);
      });
  final semanticIds = byScore(semantic), fusion = <String, double>{};
  for (final list in [keywordIds, semanticIds]) {
    for (var i = 0; i < list.length; i++) {
      fusion.update(
        list[i],
        (v) => v + 1 / (61 + i),
        ifAbsent: () => 1 / (61 + i),
      );
    }
  }
  List<int> facets(String id) {
    final c = conditions[id] ?? const RagCondition({}, {});
    final kind = intent.procedure
        ? (!c.cycle ? 2 : 0)
        : intent.cycle
        ? (c.cycle ? 2 : 0)
        : 0;
    final policy = !c.cycle
        ? 0
        : intent.policy == 'both'
        ? 2
        : ['normal', 'severe'].contains(intent.policy)
        ? (c.policies.contains(intent.policy) ? 2 : 0)
        : 0;
    final axes = intent.axes.isNotEmpty && c.axes.containsAll(intent.axes)
        ? 1
        : 0;
    return [kind, policy, axes];
  }

  final hybrid = fusion.keys.toList()
    ..sort((a, b) {
      final x = facets(a), y = facets(b);
      for (var i = 0; i < x.length; i++) {
        final c = y[i].compareTo(x[i]);
        if (c != 0) return c;
      }
      final c = fusion[b]!.compareTo(fusion[a]!);
      return c != 0 ? c : a.compareTo(b);
    });
  return RagRanking(
    byScore(chunkScores),
    semanticIds,
    hybrid,
    chunkScores,
    semantic,
    intent,
  );
}

List<MaintenanceEvidence> rankedKeywordEvidence(
  AppStore store,
  String vehicle,
  String part,
  String query, {
  DateTime? asOf,
}) {
  final items = store.searchEvidence(vehicle, part, query, asOf: asOf);
  final conditions = {
    for (final e in items)
      e.id: evidenceCondition(e, store.supportLibrary.knowledge),
  };
  final ranked = rankRag(
    chunks: const [],
    vector: const [],
    keywordIds: items.map((e) => e.id).toList(),
    conditions: conditions,
    intent: RagIntent.parse(
      query,
      store.supportLibrary.knowledge.choiceAt(asOf ?? store.clock()),
    ),
  );
  final byId = {for (final e in items) e.id: e};
  return ranked.hybridIds.map((id) => byId[id]!).toList();
}
