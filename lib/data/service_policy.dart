part of 'store.dart';

DateTime addCalendarMonths(DateTime day, int months) {
  final first = DateTime(day.year, day.month + months, 1);
  final last = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(first.year, first.month, math.min(day.day, last));
}

extension ServicePolicy on AppStore {
  Map<String, Object?> selectedRuleCriteria(
    MaintenanceRule rule, {
    DateTime? asOf,
  }) {
    final at = asOf ?? clock(), k = supportLibrary.knowledge;
    final choice = k.choiceAt(at);
    if (rule.templateId == null ||
        at.isAfter(clock()) ||
        !rule.applicabilityConfirmed ||
        !vehicles.any((v) => v.id == rule.vehicleId) ||
        rule.linkedAt == null ||
        DateTime.parse(rule.linkedAt!).isAfter(at)) {
      return {'policy': choice, 'reason': '차량·지침 적용조건 미확인'};
    }
    final template = k.templates
        .where(
          (t) => t['id'] == rule.templateId && t['conceptId'] == rule.conceptId,
        )
        .firstOrNull;
    if (template == null || template['requiresClarification'] == true) {
      return {'policy': choice, 'reason': '적용 조건 확인 불가'};
    }
    if (!['normal', 'severe'].contains(choice)) {
      return {'policy': choice, 'reason': '부대 적용 기준 미선택'};
    }
    final profile = template[choice] as Map;
    return {
      'policy': choice,
      'km': profile['km'],
      'months': profile['months'],
      'sourceRef': profile['sourceRef'],
    };
  }

  /// Replays edits/deletions backwards. Inserts carry their capture timestamp.
  List<Map<String, dynamic>> _at(
    String table,
    List<Map<String, dynamic>> current,
    DateTime at,
  ) {
    final rows = {for (final r in current) r['id'] as String: r};
    final changes = temporalChanges
        .where(
          (c) =>
              c['table'] == table && DateTime.parse(c['created']).isAfter(at),
        )
        .toList();
    // DB supplies newest rowid first; stable same-timestamp ordering is retained.
    for (final c in changes) {
      rows[c['recordId'] as String] = Map<String, dynamic>.from(
        c['before'] as Map,
      );
    }
    return rows.values.toList();
  }

  ServiceDistance evaluateKnowledgeRule(MaintenanceRule r, DateTime at) {
    final k = supportLibrary.knowledge;
    final choice = k.choiceAt(at);
    ServiceDistance hold(String why, {List<String> ids = const []}) =>
        ServiceDistance(
          reason: why,
          calendarReason: why,
          policy: choice,
          blockingRecordIds: ids,
        );
    if (at.isAfter(clock())) {
      return hold('미래 기준시각의 실제 정비 상태는 확인 불가입니다.');
    }
    if (!vehicles.any((v) => v.id == r.vehicleId)) {
      return hold('대상 차량을 확인해 주세요.');
    }
    if (!r.applicabilityConfirmed) return hold('차량·지침 적용조건 미확인');
    if (r.linkedAt == null || DateTime.parse(r.linkedAt!).isAfter(at)) {
      return hold('기준시각에 확인된 차량 연결이 없습니다.');
    }
    final template = k.templates
        .where((t) => t['id'] == r.templateId)
        .firstOrNull;
    if (template == null) return hold('주기 원문 자료를 확인해 주세요.');
    if (template['requiresClarification'] == true) {
      return hold('적용시점의 생산일·시행일 의미 확인 불가: ${template['applicabilityNote']}');
    }
    if (choice == 'unselected') return hold('부대 적용 기준(일반·가혹)을 선택해 주세요.');
    if (r.baselineConfirmedAt != null &&
        DateTime.parse(r.baselineConfirmedAt!).isAfter(at)) {
      return hold('기준시각 당시 교환 기준은 확인 불가입니다.');
    }
    final profile = template[choice] as Map;
    var date = r.baselineDate;
    int? km = r.baselineKm;
    String? basisRecord;
    final day = at.toIso8601String().substring(0, 10);
    final histories =
        _at('maintenance', records.map((r) => r.toJson()).toList(), at)
            .map(Maintenance.fromJson)
            .where(
              (h) =>
                  h.vehicleId == r.vehicleId &&
                  (recordMatchesConcept(h, r, asOf: at) ||
                      recordIsConceptCandidate(h, r, asOf: at)) &&
                  h.date.compareTo(day) <= 0 &&
                  (h.createdAt == null ||
                      !DateTime.parse(h.createdAt!).isAfter(at)),
            )
            .toList();
    final unconfirmedConcepts = histories
        .where(
          (h) =>
              recordIsConceptCandidate(h, r, asOf: at) &&
              (date.isEmpty || h.date.compareTo(date) >= 0),
        )
        .toList();
    if (unconfirmedConcepts.isNotEmpty) {
      return hold(
        '부품 개념 연결 미확인 기록이 있습니다. 후보를 검토해 주세요.',
        ids: unconfirmedConcepts.map((h) => h.id).toList(),
      );
    }
    histories.removeWhere((h) => !recordMatchesConcept(h, r, asOf: at));
    final unknownTime = histories
        .where(
          (h) =>
              h.createdAt == null &&
              (date.isEmpty || h.date.compareTo(date) >= 0),
        )
        .toList();
    if (unknownTime.isNotEmpty) {
      return hold(
        '기록의 확인시각이 없어 기준시각 조회를 확정할 수 없습니다.',
        ids: unknownTime.map((h) => h.id).toList(),
      );
    }
    final completed =
        histories.where((h) => h.replacementCompleted == true).toList()
          ..sort((a, b) {
            final c = b.date.compareTo(a.date);
            return c != 0
                ? c
                : (b.odometerKm ?? -1).compareTo(a.odometerKm ?? -1);
          });
    for (final h in completed) {
      if (date.isEmpty ||
          h.date.compareTo(date) > 0 ||
          (h.date == date && (h.odometerKm ?? -1) >= (km ?? -1))) {
        date = h.date;
        km = h.odometerKm;
        basisRecord = h.id;
        break;
      }
    }
    final unknown =
        histories
            .where(
              (h) =>
                  h.replacementCompleted == null &&
                  (date.isEmpty || h.date.compareTo(date) >= 0),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    if (unknown.isNotEmpty) {
      return hold(
        '교환 기준일 당일 또는 이후의 교환 여부 미확인 기록이 있습니다.',
        ids: unknown.map((h) => h.id).toList(),
      );
    }
    final ops =
        _at('operations', operations, at)
            .where(
              (o) =>
                  o['vehicleId'] == r.vehicleId &&
                  !DateTime.parse(o['created']).isAfter(at),
            )
            .toList()
          ..sort((a, b) {
            final c = DateTime.parse(b['created'])
                .compareTo(DateTime.parse(a['created']));
            return c != 0
                ? c
                : ((b['_localOrder'] ?? 0) as int).compareTo(
                    (a['_localOrder'] ?? 0) as int,
                  );
          });
    int? remaining, travelled;
    String? distanceReason;
    if (profile['km'] == null) {
      distanceReason = '거리 기준 수치가 원문에 없습니다.';
    } else if (km == null) {
      distanceReason = '교환 당시 계기 미확인';
    } else if (ops.isEmpty) {
      distanceReason = '기준시각 이전의 운용 계기 미확인';
    } else if (ops.first['created']
                .toString()
                .substring(0, 10)
                .compareTo(date) <
            0 ||
        (ops.first['distance'] as int) < km) {
      distanceReason = '교환 기준 이후의 유효한 운용 계기가 없습니다.';
    } else {
      travelled = (ops.first['distance'] as int) - km;
      remaining = math.max(0, (profile['km'] as int) - travelled);
    }
    DateTime? due;
    int? remainingDays;
    String? calendarReason;
    if (profile['months'] == null) {
      calendarReason = '기간 기준 수치가 원문에 없습니다.';
    } else if (date.isEmpty) {
      calendarReason = '교환일 미확인';
    } else {
      due = addCalendarMonths(DateTime.parse(date), profile['months'] as int);
      remainingDays = due
          .difference(DateTime(at.year, at.month, at.day))
          .inDays;
    }
    var first = '선도래 순서 확인 불가';
    if (remaining == 0 && remainingDays != null && remainingDays > 0) {
      first = '거리 기준 먼저 도래';
    }
    if (remainingDays != null &&
        remainingDays <= 0 &&
        remaining != null &&
        remaining > 0 &&
        ops.isNotEmpty &&
        !DateTime.parse(ops.first['created']).isBefore(due!)) {
      first = '기간 기준 먼저 도래';
    }
    if (remaining == 0 && remainingDays != null && remainingDays <= 0) {
      first = '둘 다 도래 · 선도래 순서 확인 불가';
    }
    if (due != null && km != null && profile['km'] != null) {
      final threshold = km + (profile['km'] as int);
      final relevant = ops.where(
        (o) => o['created'].toString().substring(0, 10).compareTo(date) >= 0,
      );
      if (relevant.any(
        (o) =>
            (o['distance'] as int) >= threshold &&
            DateTime.parse(o['created']).isBefore(due!),
      )) {
        first = '거리 기준 먼저 도래';
      } else if (remainingDays != null &&
          remainingDays <= 0 &&
          relevant.any(
            (o) =>
                (o['distance'] as int) < threshold &&
                !DateTime.parse(o['created']).isBefore(due!),
          )) {
        first = '기간 기준 먼저 도래';
      }
    }
    return ServiceDistance(
      remainingKm: remaining,
      travelledKm: travelled,
      reason: distanceReason,
      calendarDue: due,
      remainingDays: remainingDays,
      calendarReason: calendarReason,
      firstDue: first,
      policy: choice,
      baselineDate: date.isEmpty ? null : date,
      baselineKm: km,
      recordId: basisRecord,
      observedAt: ops.firstOrNull?['created'] as String?,
      sourceRef: Map<String, dynamic>.from(profile['sourceRef'] as Map),
    );
  }
}
