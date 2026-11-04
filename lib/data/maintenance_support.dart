part of 'store.dart';

class SupportDraft {
  const SupportDraft({this.part = '', this.query = '', this.offset = 0});
  final String part, query;
  final double offset;
}

// Local lexical expansion; retrieved text is shown without generating a diagnosis.
Set<String> maintenanceSearchTerms(String value) {
  final text = value.toLowerCase();
  final terms = text
      .split(RegExp(r'[\s,.;!?]+'))
      .where((t) => t.length > 1)
      .toSet();
  for (final term in [...terms]) {
    final stripped = term.replaceFirst(
      RegExp(r'(에서|으로|에는|이|가|을|를|은|는|도|에|의)$'),
      '',
    );
    if (stripped.length > 1) terms.add(stripped);
  }
  for (final concept in [
    '시동',
    '소음',
    '진동',
    '누유',
    '누수',
    '과열',
    '제동',
    '충전',
    '경고등',
  ]) {
    if (text.contains(concept)) terms.add(concept);
  }
  if (RegExp(r'걸리지|안\s*걸|시동\s*불량').hasMatch(text)) terms.add('시동 불량');
  return terms;
}

/// Shared vocabulary for document metadata, maintenance records and images.
const standardParts = <String, List<String>>{
  '엔진오일': ['engine_oil', '엔진 오일'],
  '오일필터': ['oil_filter', '오일 필터'],
  '에어필터': ['air_filter', '에어 필터', '흡기필터'],
  '연료필터': ['fuel_filter', '연료 필터'],
  '브레이크패드': ['brake_pad', 'brake pad', '브레이크 패드', '제동패드'],
  '브레이크호스': ['brake_hose', '브레이크 호스', '제동호스'],
  '타이어': ['tire', 'tyre'],
  '배터리': ['battery', '축전지'],
  '냉각수호스': ['coolant_hose', '냉각수 호스'],
  '전조등': ['headlight', '헤드라이트'],
};

String _compact(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');

String standardPart(String value) {
  final input = _compact(value);
  for (final entry in standardParts.entries) {
    if ([entry.key, ...entry.value].any((v) => _compact(v) == input)) {
      return entry.key;
    }
  }
  return value.trim();
}

Set<String> partsIn(String value) {
  final input = _compact(value);
  return {
    for (final entry in standardParts.entries)
      if ([entry.key, ...entry.value].any((v) => input.contains(_compact(v))))
        entry.key,
  };
}

bool matchesPart(String text, String part) =>
    _compact(text).contains(_compact(standardPart(part))) ||
    partsIn(text).contains(standardPart(part));

String replacementStatusLabel(bool? value) => switch (value) {
  null => '미확인',
  false => '교환 없음',
  true => '교환 완료',
};

class MaintenanceEvidence {
  const MaintenanceEvidence({
    required this.id,
    required this.model,
    required this.part,
    required this.symptoms,
    required this.title,
    required this.location,
    required this.text,
    this.conceptId,
    this.sourceRef,
  });
  final String id, model, part, symptoms, title, location, text;
  final String? conceptId;
  final Map<String, dynamic>? sourceRef;
  Map<String, dynamic> toJson() => {
    'id': id,
    'model': model,
    'part': part,
    'symptoms': symptoms,
    'title': title,
    'location': location,
    'text': text,
    if (conceptId != null) 'conceptId': conceptId,
    if (sourceRef != null) 'sourceRef': sourceRef,
  };
  factory MaintenanceEvidence.fromJson(Map<String, dynamic> j) =>
      MaintenanceEvidence(
        id: j['id'],
        model: j['model'],
        part: j['part'],
        symptoms: j['symptoms'],
        title: j['title'],
        location: j['location'],
        text: j['text'],
        conceptId: j['conceptId'],
        sourceRef: j['sourceRef'] == null
            ? null
            : Map<String, dynamic>.from(j['sourceRef']),
      );
}

class MaintenanceRule {
  const MaintenanceRule({
    required this.id,
    required this.vehicleId,
    required this.part,
    required this.intervalKm,
    required this.baselineKm,
    required this.baselineDate,
    required this.source,
    this.templateId,
    this.conceptId,
    this.applicabilityConfirmed = false,
    this.linkedAt,
    this.baselineConfirmedAt,
  });
  final String id, vehicleId, part, baselineDate, source;
  final int? intervalKm, baselineKm;
  final String? templateId, conceptId, linkedAt, baselineConfirmedAt;
  final bool applicabilityConfirmed;
  Map<String, dynamic> toJson() => {
    'id': id,
    'vehicleId': vehicleId,
    'part': part,
    'intervalKm': intervalKm,
    'baselineKm': baselineKm,
    'baselineDate': baselineDate,
    'source': source,
    if (templateId != null) ...{
      'templateId': templateId,
      'conceptId': conceptId,
      'applicabilityConfirmed': applicabilityConfirmed,
      'linkedAt': linkedAt,
      'baselineConfirmedAt': baselineConfirmedAt,
    },
  };
  factory MaintenanceRule.fromJson(Map<String, dynamic> j) => MaintenanceRule(
    id: j['id'],
    vehicleId: j['vehicleId'],
    part: j['part'],
    intervalKm: j['intervalKm'],
    baselineKm: j['baselineKm'],
    baselineDate: j['baselineDate'],
    source: j['source'],
    templateId: j['templateId'],
    conceptId: j['conceptId'],
    applicabilityConfirmed: j['applicabilityConfirmed'] == true,
    linkedAt: j['linkedAt'],
    baselineConfirmedAt: j['baselineConfirmedAt'],
  );
}

class SupportLibrary {
  const SupportLibrary({
    this.evidence = const [],
    this.rules = const [],
    this.knowledge = const KnowledgeData(),
  });
  final List<MaintenanceEvidence> evidence;
  final List<MaintenanceRule> rules;
  final KnowledgeData knowledge;
  SupportLibrary copyWith({
    List<MaintenanceEvidence>? evidence,
    List<MaintenanceRule>? rules,
    KnowledgeData? knowledge,
  }) => SupportLibrary(
    evidence: evidence ?? this.evidence,
    rules: rules ?? this.rules,
    knowledge: knowledge ?? this.knowledge,
  );
  String encode() => jsonEncode({
    'version': 2,
    'evidence': evidence.map((e) => e.toJson()).toList(),
    'rules': rules.map((e) => e.toJson()).toList(),
    'knowledge': knowledge.toJson(),
  });

  static SupportLibrary decode(String value) {
    const error = FormatException('정비지원 자료의 형식과 입력 범위를 확인해 주세요.');
    if (value.length > 4000000) throw error;
    final j = jsonDecode(value);
    if (j is! Map ||
        ![1, 2].contains(j['version']) ||
        j['evidence'] is! List ||
        j['rules'] is! List ||
        j['evidence'].length > 1000 ||
        j['rules'].length > 1000) {
      throw error;
    }
    bool text(dynamic x, int max) =>
        x is String && x.trim().isNotEmpty && x.length <= max;
    final knowledge = KnowledgeData.fromJson(j['knowledge']);
    final ids = <String>{};
    for (final r in [...j['evidence'], ...j['rules']]) {
      if (r is! Map ||
          !text(r['id'], 120) ||
          !ids.add(r['id']) ||
          !text(r['part'], 300)) {
        throw error;
      }
    }
    for (final r in j['evidence']) {
      if (r['conceptId'] != null) {
        knowledge.requireConcept(r['conceptId']);
        validateSourceRef(r['sourceRef']);
      }
      if (!text(r['model'], 300) ||
          !text(r['title'], 300) ||
          !text(r['location'], 300) ||
          !text(r['text'], 10000) ||
          r['symptoms'] is! String ||
          r['symptoms'].length > 1000) {
        throw error;
      }
    }
    final keys = <String>{};
    for (final r in j['rules']) {
      final date = r['baselineDate'] is String
          ? DateTime.tryParse(r['baselineDate'])
          : null;
      if (!text(r['vehicleId'], 120) ||
          !text(r['source'], 1000) ||
          (r['templateId'] == null &&
              (r['intervalKm'] is! int ||
                  r['intervalKm'] <= 0 ||
                  r['intervalKm'] > 1000000 ||
                  r['baselineKm'] is! int ||
                  r['baselineKm'] < 0 ||
                  r['baselineKm'] > 1000000000000 ||
                  date == null ||
                  r['baselineDate'] !=
                      date.toIso8601String().substring(0, 10))) ||
          !keys.add('${r['vehicleId']}|${standardPart(r['part'])}')) {
        throw error;
      }
      if (r['templateId'] != null) knowledge.validateRule(r);
    }
    return SupportLibrary(
      knowledge: knowledge,
      evidence: [
        for (final r in j['evidence'])
          MaintenanceEvidence.fromJson(Map<String, dynamic>.from(r)),
      ],
      rules: [
        for (final r in j['rules'])
          MaintenanceRule.fromJson(Map<String, dynamic>.from(r)),
      ],
    );
  }
}

class ServiceDistance {
  const ServiceDistance({
    this.remainingKm,
    this.travelledKm,
    this.reason,
    this.baselineDate,
    this.baselineKm,
    this.recordId,
    this.blockingRecordIds = const [],
    this.calendarDue,
    this.remainingDays,
    this.calendarReason,
    this.firstDue = '선도래 순서 확인 불가',
    this.policy,
    this.observedAt,
    this.sourceRef,
  });
  final int? remainingKm, travelledKm;
  final String? reason;
  final String? baselineDate, recordId;
  final int? baselineKm;
  final List<String> blockingRecordIds;
  final DateTime? calendarDue;
  final int? remainingDays;
  final String? calendarReason, policy;
  final String firstDue;
  final String? observedAt;
  final Map<String, dynamic>? sourceRef;
}

extension MaintenanceSupport on AppStore {
  Future<void> saveSupportLibrary(SupportLibrary library) =>
      updateSupportLibrary((_) => library);

  Future<void> updateSupportLibrary(
    SupportLibrary Function(SupportLibrary) update,
  ) => _mutate(() => _writeSupportLibrary(update(supportLibrary)));

  Future<void> _writeSupportLibrary(SupportLibrary library) async {
    final checked = SupportLibrary.decode(library.encode());
    for (final r in checked.rules) {
      if (!vehicles.any((v) => v.id == r.vehicleId) ||
          (r.baselineKm != null &&
              r.baselineKm! > vehicle(r.vehicleId).distance) ||
          (r.baselineDate.isNotEmpty &&
              (DateTime.parse(r.baselineDate).isAfter(clock()) ||
                  DateTime.parse(r.baselineDate).year <
                      vehicle(r.vehicleId).year))) {
        throw ArgumentError('기준 날짜·주행거리와 대상 차량을 확인해 주세요.');
      }
    }
    await db!.customStatement(
      'INSERT OR REPLACE INTO app_metadata (key,value) VALUES (?,?)',
      ['maintenance_support', checked.encode()],
    );
    supportLibrary = checked;
    _notifyChanged();
  }

  ServiceDistance serviceDistance(MaintenanceRule r, {DateTime? asOf}) {
    if (r.templateId != null) return evaluateKnowledgeRule(r, asOf ?? clock());
    if (asOf != null) {
      return const ServiceDistance(reason: '기존 수동 거리 주기의 과거 기준 조회는 확인 불가입니다.');
    }
    final v = vehicles.where((v) => v.id == r.vehicleId).firstOrNull;
    if (v == null ||
        r.baselineKm! > v.distance ||
        DateTime.parse(r.baselineDate).isAfter(clock())) {
      return const ServiceDistance(reason: '기준 날짜·주행거리를 확인해 주세요.');
    }
    var basisDate = r.baselineDate;
    var basisKm = r.baselineKm!;
    String? basisRecord;
    // The completion record is the source of truth. Editing or deleting it
    // automatically recalculates the plan without leaving a stale cached rule.
    final replacements =
        history(v.id)
            .where(
              (h) =>
                  matchesPart(h.part, r.part) &&
                  h.replacementCompleted == true &&
                  h.odometerKm != null,
            )
            .toList()
          ..sort((a, b) {
            final c = b.date.compareTo(a.date);
            return c != 0 ? c : b.odometerKm!.compareTo(a.odometerKm!);
          });
    for (final h in replacements) {
      if (h.date.compareTo(clock().toIso8601String().substring(0, 10)) > 0) {
        return ServiceDistance(
          reason: '교환 날짜가 미래입니다. 기록을 확인해 주세요.',
          blockingRecordIds: [h.id],
        );
      }
      if (h.date.compareTo(basisDate) > 0 ||
          (h.date == basisDate && h.odometerKm! >= basisKm)) {
        basisDate = h.date;
        basisKm = h.odometerKm!;
        basisRecord = h.id;
        break;
      }
    }
    if (basisKm > v.distance) {
      return ServiceDistance(
        reason: '교환 계기가 현재 운용 계기보다 큽니다. 기록을 확인해 주세요.',
        blockingRecordIds: [?basisRecord],
      );
    }
    final unknownRecords =
        history(v.id)
            .where(
              (h) =>
                  h.date.compareTo(basisDate) >= 0 &&
                  matchesPart(h.part, r.part) &&
                  h.replacementCompleted == null,
            )
            .toList()
          ..sort((a, b) {
            final date = b.date.compareTo(a.date);
            return date != 0 ? date : a.id.compareTo(b.id);
          });
    if (unknownRecords.isNotEmpty) {
      return ServiceDistance(
        reason: '교환 기준일 당일 또는 이후에 교환 여부 미확인 기록이 있습니다. 작업 순서를 확인하고 마지막 교환 기준을 갱신해 주세요.',
        blockingRecordIds: List.unmodifiable(unknownRecords.map((h) => h.id)),
      );
    }
    final travelled = v.distance - basisKm;
    return ServiceDistance(
      remainingKm: math.max(0, r.intervalKm! - travelled),
      travelledKm: travelled,
      baselineDate: basisDate,
      baselineKm: basisKm,
      recordId: basisRecord,
    );
  }

  List<MaintenanceEvidence> searchEvidence(
    String vehicleId,
    String part,
    String query, {
    DateTime? asOf,
  }) {
    final terms = maintenanceSearchTerms(query);
    int score(MaintenanceEvidence e) {
      final text = '${e.symptoms} ${e.text} ${e.part}'.toLowerCase();
      return terms.where(text.contains).length +
          partsIn(query).where((p) => matchesPart(e.part, p)).length * 3;
    }

    final result = eligibleEvidence(
      vehicleId,
      part,
      asOf: asOf,
    ).where((e) => query.trim().isEmpty || score(e) > 0).toList();
    result.sort((a, b) {
      final c = score(b).compareTo(score(a));
      return c == 0 ? a.id.compareTo(b.id) : c;
    });
    return result.take(5).toList();
  }

  List<MaintenanceEvidence> eligibleEvidence(
    String vehicleId,
    String part, {
    DateTime? asOf,
  }) {
    final model = vehicle(vehicleId).model;
    return supportLibrary.evidence
        .where(
          (e) =>
              (e.conceptId == null
                  ? asOf == null && e.model == model
                  : supportLibrary.rules.any(
                      (r) =>
                          r.vehicleId == vehicleId &&
                          r.conceptId == e.conceptId &&
                          r.applicabilityConfirmed &&
                          supportLibrary.knowledge.templates.any(
                            (t) =>
                                t['id'] == r.templateId &&
                                ['normal', 'severe'].any(
                                  (p) =>
                                      t[p]['sourceRef']['file'] ==
                                          e.sourceRef?['file'] &&
                                      t[p]['sourceRef']['sha256'] ==
                                          e.sourceRef?['sha256'],
                                ),
                          ) &&
                          r.linkedAt != null &&
                          !DateTime.parse(r.linkedAt!).isAfter(asOf ?? clock()),
                    )) &&
              (part.isEmpty ||
                  (e.conceptId != null
                      ? e.conceptId == supportLibrary.knowledge.conceptFor(part)
                      : standardPart(e.part) == standardPart(part))),
        )
        .toList();
  }

  List<Maintenance> relatedMaintenance(
    String vehicleId,
    String part,
    String query, {
    DateTime? asOf,
    bool includeCandidates = false,
  }) {
    final parts = partsIn(query);
    final terms = maintenanceSearchTerms(query);
    final historyRows =
        asOf == null
              ? history(vehicleId)
              : _at(
                      'maintenance',
                      records.map((r) => r.toJson()).toList(),
                      asOf,
                    )
                    .map(Maintenance.fromJson)
                    .where(
                      (r) =>
                          r.vehicleId == vehicleId &&
                          r.createdAt != null &&
                          !DateTime.parse(r.createdAt!).isAfter(asOf) &&
                          r.date.compareTo(
                                asOf.toIso8601String().substring(0, 10),
                              ) <=
                              0,
                    )
                    .toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    return historyRows
        .where((r) {
          if (part.isNotEmpty) {
            final concept = supportLibrary.knowledge.conceptFor(part);
            return concept == null
                ? matchesPart(r.part, part)
                : r.conceptAt(asOf ?? clock()) == concept ||
                      (includeCandidates &&
                          r.conceptAt(asOf ?? clock()) == null &&
                          (r.conceptId == concept ||
                              supportLibrary.knowledge.conceptFor(r.part) ==
                                  concept));
          }
          if (query.trim().isEmpty) return true;
          final text = '${r.part} ${r.description}'.toLowerCase();
          return parts.any((p) => matchesPart(r.part, p)) ||
              terms.any(text.contains);
        })
        .take(12)
        .toList();
  }

  /// First due date only; no repeated replacements are assumed in an annual plan.
  DateTime? estimatedServiceDate(MaintenanceRule rule) {
    // Imported dual criteria are shown independently; no distance date is
    // invented to place them on the legacy mileage forecast calendar.
    if (rule.templateId != null) return null;
    final remaining = serviceDistance(rule).remainingKm;
    if (remaining == null) return null;
    final now = clock();
    final today = DateTime(now.year, now.month, now.day);
    if (remaining == 0) return today;
    // Mileage forecasts use calendar days, independent of DST hour changes.
    int age(DateTime value) => calendarDaysBetween(now, value);
    final rows =
        operations
            .where(
              (r) =>
                  r['vehicleId'] == rule.vehicleId &&
                  !DateTime.parse(r['created']).isAfter(now) &&
                  age(DateTime.parse(r['created'])) < 90,
            )
            .toList()
          ..sort(
            (a, b) =>
                (a['created'] as String).compareTo(b['created'] as String),
          );
    if (rows.length < 2) return null;
    final days = calendarDaysBetween(
      DateTime.parse(rows.last['created']),
      DateTime.parse(rows.first['created']),
    );
    final km = (rows.last['distance'] as int) - (rows.first['distance'] as int);
    if (days < 7 || km <= 0) return null;
    // Reject inconsistent or reversed cumulative readings.
    for (var i = 1; i < rows.length; i++) {
      if ((rows[i]['distance'] as int) < (rows[i - 1]['distance'] as int)) {
        return null;
      }
    }
    final firstDate = DateTime.parse(rows.first['created']);
    if (age(DateTime.parse(rows.last['created'])) > 30 ||
        firstDate.isAfter(now)) {
      return null;
    }
    return DateTime(
      now.year,
      now.month,
      now.day + (remaining * days / km).ceil(),
    );
  }
}
