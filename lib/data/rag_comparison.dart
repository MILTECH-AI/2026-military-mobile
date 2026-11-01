import 'rag_ranking.dart';

Map<String, Object?> compareRagRanks(Map pc, RagRanking android) {
  final layers = <String, Object?>{};
  var evidenceEqual = true;
  for (final pair in [
    ('chunks', android.chunkIds),
    ('semantic', android.semanticIds),
    ('hybrid', android.hybridIds),
  ]) {
    final expected = List<String>.from(pc[pair.$1] as List);
    final results = <String, Object?>{};
    for (final k in [1, 3, 5]) {
      final a = expected.take(k).toList(), b = pair.$2.take(k).toList();
      final same =
          a.length == b.length &&
          List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
      if (pair.$1 != 'chunks' && !same) evidenceEqual = false;
      results['$k'] = {
        'orderedEqual': same,
        'overlapCount': a.toSet().intersection(b.toSet()).length,
        'pc': a,
        'android': b,
      };
    }
    layers[pair.$1] = results;
  }
  final pcScores = Map<String, num>.from(pc['semanticScores'] as Map);
  final differences = [
    for (final id in pcScores.keys)
      {
        'id': id,
        'pc': pcScores[id],
        'android': android.semanticScores[id],
        'delta': android.semanticScores[id]! - pcScores[id]!,
      },
  ];
  return {
    'evidenceRanksEqual': evidenceEqual,
    'layers': layers,
    'scores': differences,
    'context': android.intent.toJson(),
  };
}
