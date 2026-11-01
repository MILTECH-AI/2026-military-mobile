part of 'store.dart';

const _knowledgeError = FormatException('반입 자료의 형식·근거·참조를 확인해 주세요.');
bool _kText(dynamic x, [int max = 300]) =>
    x is String && x.trim().isNotEmpty && x.length <= max;
bool _kId(dynamic x) =>
    x is String && RegExp(r'^[A-Za-z0-9가-힣_-]{1,120}$').hasMatch(x);
bool _kDate(dynamic x) =>
    x is String &&
    DateTime.tryParse(x) != null &&
    x == DateTime.parse(x).toIso8601String().substring(0, 10);
bool _kTime(dynamic x) =>
    x is String &&
    x.length <= 40 &&
    x.contains('T') &&
    DateTime.tryParse(x) != null;
void validateSourceRef(dynamic value) {
  if (value is! Map ||
      !_kText(value['file']) ||
      value['file'].contains(RegExp(r'[/\\]')) ||
      value['page'] is! int ||
      value['page'] <= 0 ||
      value['page'] > 100000 ||
      value['sha256'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256']) ||
      !_kText(value['location'], 1000)) {
    throw _knowledgeError;
  }
}

class KnowledgeData {
  const KnowledgeData({
    this.concepts = const [],
    this.skus = const [],
    this.templates = const [],
    this.pending = const [],
    this.policyHistory = const [],
    this.imports = const {},
  });
  final List<Map<String, dynamic>> concepts,
      skus,
      templates,
      pending,
      policyHistory;
  final Map<String, dynamic> imports;
  Map<String, dynamic> toJson() => {
    'concepts': concepts,
    'skus': skus,
    'templates': templates,
    'pending': pending,
    'policyHistory': policyHistory,
    'imports': imports,
  };
  KnowledgeData copyWith({
    List<Map<String, dynamic>>? concepts,
    List<Map<String, dynamic>>? skus,
    List<Map<String, dynamic>>? templates,
    List<Map<String, dynamic>>? pending,
    List<Map<String, dynamic>>? policyHistory,
    Map<String, dynamic>? imports,
  }) => KnowledgeData(
    concepts: concepts ?? this.concepts,
    skus: skus ?? this.skus,
    templates: templates ?? this.templates,
    pending: pending ?? this.pending,
    policyHistory: policyHistory ?? this.policyHistory,
    imports: imports ?? this.imports,
  );
  void requireConcept(dynamic id) {
    if (!_kId(id) || !concepts.any((c) => c['id'] == id)) throw _knowledgeError;
  }

  String? conceptFor(String name) {
    final found = concepts
        .where(
          (c) => [
            c['name'],
            ...c['aliases'] as List,
          ].any((s) => _compact(s as String) == _compact(name)),
        )
        .toList();
    return found.length == 1 ? found.single['id'] as String : null;
  }

  String choiceAt(DateTime at) {
    DateTime? latest;
    var choice = 'unselected';
    for (final p in policyHistory) {
      final time = DateTime.parse(p['at']);
      if (!time.isAfter(at) && (latest == null || !time.isBefore(latest))) {
        latest = time;
        choice = p['choice'] as String;
      }
    }
    return choice;
  }

  void validateRule(Map r) {
    if (r['intervalKm'] != null ||
        conceptFor(r['part'] as String) != r['conceptId']) {
      throw _knowledgeError;
    }
    requireConcept(r['conceptId']);
    if (!templates.any(
          (t) => t['id'] == r['templateId'] && t['conceptId'] == r['conceptId'],
        ) ||
        r['applicabilityConfirmed'] is! bool ||
        !_kTime(r['linkedAt']) ||
        (r['baselineDate'] != '' && !_kDate(r['baselineDate'])) ||
        (r['baselineKm'] != null &&
            (r['baselineKm'] is! int ||
                r['baselineKm'] < 0 ||
                r['baselineKm'] > 1000000000000)) ||
        (r['baselineConfirmedAt'] != null &&
            !_kTime(r['baselineConfirmedAt']))) {
      throw _knowledgeError;
    }
    if ((r['baselineDate'] != '' || r['baselineKm'] != null) &&
        r['baselineConfirmedAt'] == null) {
      throw _knowledgeError;
    }
  }

  static KnowledgeData fromJson(dynamic raw) {
    if (raw == null) return const KnowledgeData();
    if (raw is! Map) throw _knowledgeError;
    List<Map<String, dynamic>> list(String key) {
      final xs = raw[key] ?? [];
      if (xs is! List || xs.length > 1000 || xs.any((x) => x is! Map)) {
        throw _knowledgeError;
      }
      return [for (final x in xs) Map<String, dynamic>.from(x as Map)];
    }

    final imp = raw['imports'] ?? <String, dynamic>{};
    if (imp is! Map || imp.length > 1000) throw _knowledgeError;
    final k = KnowledgeData(
      concepts: list('concepts'),
      skus: list('skus'),
      templates: list('templates'),
      pending: list('pending'),
      policyHistory: list('policyHistory'),
      imports: Map<String, dynamic>.from(imp),
    );
    final ids = <String>{}, aliases = <String, String>{};
    for (final c in k.concepts) {
      if (!_kId(c['id']) ||
          !ids.add(c['id']) ||
          !_kText(c['name']) ||
          c['aliases'] is! List ||
          (c['aliases'] as List).length > 100) {
        throw _knowledgeError;
      }
      for (final s in [c['name'], ...c['aliases'] as List]) {
        if (!_kText(s)) throw _knowledgeError;
        final key = _compact(s);
        if (aliases.containsKey(key) && aliases[key] != c['id']) {
          throw _knowledgeError;
        }
        aliases[key] = c['id'];
      }
    }
    for (final s in k.skus) {
      k.requireConcept(s['conceptId']);
      if (!_kId(s['id']) ||
          !ids.add(s['id']) ||
          !_kText(s['partNumber'], 100) ||
          s['partNumber'] is! String ||
          !_kText(s['name']) ||
          s['conditions'] is! String ||
          (s['conditions'] as String).length > 2000 ||
          s['applicability'] != 'unconfirmed') {
        throw _knowledgeError;
      }
      validateSourceRef(s['sourceRef']);
    }
    for (final t in k.templates) {
      k.requireConcept(t['conceptId']);
      if (!_kId(t['id']) ||
          !ids.add(t['id']) ||
          !_kText(t['applicabilityNote'], 2000) ||
          t['requiresClarification'] is! bool) {
        throw _knowledgeError;
      }
      for (final choice in ['normal', 'severe']) {
        final p = t[choice];
        if (p is! Map ||
            (p['km'] != null &&
                (p['km'] is! int || p['km'] <= 0 || p['km'] > 1000000)) ||
            (p['months'] != null &&
                (p['months'] is! int ||
                    p['months'] <= 0 ||
                    p['months'] > 1200)) ||
            !_kText(p['note'], 2000)) {
          throw _knowledgeError;
        }
        validateSourceRef(p['sourceRef']);
      }
    }
    for (final p in k.pending) {
      final r = p['record'];
      if (r is Map &&
          ((r['maintenanceType'] != null && r['maintenanceType'] != '미분류') ||
              r['inspectionId'] != null ||
              r['createdAt'] != null ||
              r['updatedAt'] != null)) {
        throw _knowledgeError;
      }
      if (p['verification'] != 'unverified' ||
          r is! Map ||
          !_kId(r['id']) ||
          !ids.add(r['id']) ||
          !_kId(r['vehicleId']) ||
          !_kDate(r['date']) ||
          !_kText(r['part']) ||
          r['description'] is! String ||
          r['description'].length > 5000 ||
          r['cost'] is! int ||
          r['cost'] < 0 ||
          r['cost'] > 1000000000000 ||
          r['replacementCompleted'] != null ||
          r['odometerKm'] != null ||
          ![
            '냉각',
            '제동',
            '엔진/연료',
            '전장',
            '조향/현가',
            '흡기/배기',
            '동력전달',
            '공조',
            '차체',
          ].contains(r['system'])) {
        throw _knowledgeError;
      }
      k.requireConcept(r['conceptId']);
      // Same record model as active maintenance, with separate review status.
      Maintenance.fromJson(Map<String, dynamic>.from(r));
      validateSourceRef(p['sourceRef']);
    }
    for (final p in k.policyHistory) {
      if (!_kTime(p['at']) ||
          !['unselected', 'normal', 'severe'].contains(p['choice'])) {
        throw _knowledgeError;
      }
    }
    for (final e in k.imports.entries) {
      if (!_kId(e.key) ||
          e.value is! Map ||
          !_kTime(e.value['at']) ||
          !_kText(e.value['fingerprint'], 4000000)) {
        throw _knowledgeError;
      }
    }
    return k;
  }
}

class KnowledgeBundle {
  KnowledgeBundle._(this.id, this.library);
  final String id;
  final SupportLibrary library;
  String get fingerprint => library.encode();
  static KnowledgeBundle decode(String value) {
    if (value.length > 4000000) throw _knowledgeError;
    final raw = jsonDecode(value);
    if (raw is! Map ||
        raw['format'] != 'maintenance-knowledge' ||
        raw['version'] != 1 ||
        !_kId(raw['id'])) {
      throw _knowledgeError;
    }
    final library = SupportLibrary.decode(
      jsonEncode({
        'version': 2,
        'evidence': raw['evidence'],
        'rules': [],
        'knowledge': raw['knowledge'],
      }),
    );
    if (library.knowledge.policyHistory.isNotEmpty ||
        library.knowledge.imports.isNotEmpty) {
      throw _knowledgeError;
    }
    return KnowledgeBundle._(raw['id'], library);
  }
}

extension KnowledgeImport on AppStore {
  Future<bool> importKnowledge(KnowledgeBundle bundle) => _mutate(() async {
    final b = SupportLibrary.decode(bundle.library.encode());
    final old = supportLibrary.knowledge;
    final receipt = old.imports[bundle.id];
    if (receipt != null) {
      if (receipt['fingerprint'] != bundle.fingerprint) {
        throw const FormatException('같은 반입 ID의 내용이 변경되었습니다. 새 개정 ID로 검토해 주세요.');
      }
      return false;
    }
    final merged = supportLibrary.copyWith(
      evidence: [...supportLibrary.evidence, ...b.evidence],
      knowledge: old.copyWith(
        concepts: [...old.concepts, ...b.knowledge.concepts],
        skus: [...old.skus, ...b.knowledge.skus],
        templates: [...old.templates, ...b.knowledge.templates],
        pending: [...old.pending, ...b.knowledge.pending],
        imports: {
          ...old.imports,
          bundle.id: {
            'at': clock().toIso8601String(),
            'fingerprint': bundle.fingerprint,
          },
        },
      ),
    );
    final checked = SupportLibrary.decode(merged.encode());
    await db!.transaction(() async {
      await db!.customStatement(
        'INSERT OR REPLACE INTO app_metadata (key,value) VALUES (?,?)',
        ['maintenance_support', checked.encode()],
      );
    });
    supportLibrary = checked;
    _notifyChanged();
    return true;
  });

  Future<void> selectServicePolicy(String choice) => updateSupportLibrary((s) {
    if (!['unselected', 'normal', 'severe'].contains(choice)) {
      throw _knowledgeError;
    }
    final at = clock().toIso8601String();
    return s.copyWith(
      knowledge: s.knowledge.copyWith(
        policyHistory: [
          ...s.knowledge.policyHistory,
          {'at': at, 'choice': choice},
        ],
      ),
    );
  });

  bool recordMatchesConcept(
    Maintenance record,
    MaintenanceRule rule, {
    DateTime? asOf,
  }) => rule.conceptId == null
      ? matchesPart(record.part, rule.part)
      : record.conceptAt(asOf ?? clock()) == rule.conceptId;

  bool recordIsConceptCandidate(
    Maintenance record,
    MaintenanceRule rule, {
    DateTime? asOf,
  }) =>
      rule.conceptId != null &&
      record.conceptAt(asOf ?? clock()) == null &&
      (record.conceptId == rule.conceptId ||
          supportLibrary.knowledge.conceptFor(record.part) == rule.conceptId);
}
