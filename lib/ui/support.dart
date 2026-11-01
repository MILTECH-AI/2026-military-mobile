import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/store.dart';
import '../data/adaptive_runtime.dart';
import '../data/local_rag.dart';
import '../data/rag_ranking.dart';
import '../data/local_summary.dart';
import 'components.dart';
import 'knowledge_tools.dart';

String supportUrl(String vehicle, [String part = '', String? inspectionId]) =>
    Uri(
      path: '/support',
      queryParameters: {
        'vehicle': vehicle,
        if (part.isNotEmpty) 'part': standardPart(part),
        'inspection': ?inspectionId,
      },
    ).toString();

class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({
    this.vehicleId,
    this.part,
    this.inspectionId,
    super.key,
  });
  final String? vehicleId;
  final String? part;
  final String? inspectionId;
  @override
  ConsumerState<SupportScreen> createState() => _SupportState();
}

class _SupportState extends ConsumerState<SupportScreen> {
  GroundedSummary? summary;
  Map<String, MaintenanceEvidence> summarySources = {};
  String? summaryKey;
  bool summaryBusy = false;
  Future<void> summarize(List<MaintenanceEvidence> evidence) async {
    if (summaryBusy) return;
    final key = searchKey(store);
    setState(() => summaryBusy = true);
    try {
      final result = await LocalSummary.summarize(
        ref.read(adaptiveRuntimeProvider),
        query.text,
        evidence,
      );
      if (mounted && key == searchKey(store)) {
        setState(() {
          summary = result;
          summaryKey = key;
          summarySources = {for (final e in evidence.take(2)) e.id: e};
        });
      }
    } finally {
      if (mounted) setState(() => summaryBusy = false);
    }
  }

  final query = TextEditingController();
  late final AppStore store;
  late final ScrollController scroll;
  String? vehicle;
  String part = '';
  bool savingQuestion = false;
  DateTime? evaluationAt;
  RagSearchResult? hybridResult;
  String? hybridKey;
  bool embeddingBusy = false;
  String searchKey(AppStore s) =>
      '$vehicle|$part|${query.text}|$evaluationAt|${s.supportLibrary.encode()}';
  Future<void> searchHybrid() async {
    if (embeddingBusy || vehicle == null) return;
    final s = ref.read(storeProvider);
    final key = searchKey(s);
    setState(() => embeddingBusy = true);
    final result = await LocalRag(ref.read(adaptiveRuntimeProvider))
        .search(s, vehicle!, part, query.text, asOf: evaluationAt);
    if (!mounted) return;
    setState(() {
      embeddingBusy = false;
      if (key == searchKey(s)) {
        hybridKey = key;
        hybridResult = result;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    store = ref.read(storeProvider);
    final requested = widget.vehicleId ?? store.lastSupportVehicle;
    vehicle = store.vehicles.any((v) => v.id == requested)
        ? requested
        : store.activeVehicles.firstOrNull?.id;
    final draft = store.supportDrafts[vehicle] ?? const SupportDraft();
    part = widget.part == null ? draft.part : standardPart(widget.part!);
    query.text = widget.part == null || part == draft.part ? draft.query : '';
    scroll = ScrollController(
      initialScrollOffset: widget.part == null || part == draft.part
          ? draft.offset
          : 0,
    );
    scroll.addListener(remember);
  }

  void remember() {
    if (vehicle == null) return;
    store.lastSupportVehicle = vehicle;
    store.supportDrafts[vehicle!] = SupportDraft(
      part: part,
      query: query.text,
      offset: scroll.hasClients
          ? scroll.offset
          : (store.supportDrafts[vehicle!]?.offset ?? 0),
    );
  }

  @override
  void dispose() {
    remember();
    scroll.dispose();
    query.dispose();
    super.dispose();
  }

  Future<void> saveQuestion() async {
    if (query.text.trim().isEmpty) return;
    setState(() => savingQuestion = true);
    try {
      await ref
          .read(storeProvider)
          .saveQuestion(vehicle!, query.text.trim(), partName: part);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('질문을 기기에 저장했습니다.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('질문을 저장하지 못했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => savingQuestion = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    if (s.vehicles.isEmpty) return empty('등록된 차량이 없습니다.');
    vehicle ??= s.vehicles.any((v) => v.id == widget.vehicleId)
        ? widget.vehicleId
        : s.vehicles.first.id;
    if (!s.vehicles.any((v) => v.id == vehicle)) vehicle = s.vehicles.first.id;
    final v = s.vehicle(vehicle!);
    final parts = {
      ...standardParts.keys,
      ...s.supportLibrary.evidence.map((e) => standardPart(e.part)),
      ...s.supportLibrary.rules.map((r) => standardPart(r.part)),
      if (part.isNotEmpty) part,
    }.toList();
    final keywordEvidence = rankedKeywordEvidence(
      s,
      v.id,
      part,
      query.text,
      asOf: evaluationAt,
    );
    final currentHybrid = hybridKey == searchKey(s) ? hybridResult : null;
    final evidence = currentHybrid?.evidence ?? keywordEvidence;
    final linkedInspection = s.inspections
        .where(
          (i) =>
              i.id == widget.inspectionId &&
              i.vehicleId == v.id &&
              standardPart(i.area) == part,
        )
        .firstOrNull;
    final records = s.relatedMaintenance(
      v.id,
      part,
      query.text,
      asOf: evaluationAt,
      includeCandidates: true,
    );
    final rules = s.supportLibrary.rules
        .where(
          (r) =>
              r.vehicleId == v.id &&
              (part.isEmpty || standardPart(r.part) == part),
        )
        .toList();
    final inspections = s.inspections
        .where(
          (i) =>
              i.vehicleId == v.id &&
              (part.isEmpty || matchesPart(i.area, part)),
        )
        .take(6)
        .toList();
    return ListView(
      controller: scroll,
      children: [
        PageTitle(
          'AI 정비지원',
          '차량·차종·표준부품·시간을 기준으로 정비거리, 문서 근거와 현장 기록을 연결합니다.',
          scopeVehicles: [v],
        ),
        Panel(
          title: '지원 대상',
          subtitle: '등록 문서 검색 · 자동 답변 미연결 · 기기 내 처리',
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey(vehicle),
                initialValue: vehicle,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '차량 / 차종'),
                items: s.vehicles
                    .map(
                      (v) => DropdownMenuItem(
                        value: v.id,
                        child: Text('${v.id} · ${v.model}'),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() {
                  remember();
                  vehicle = value;
                  final draft =
                      store.supportDrafts[vehicle] ?? const SupportDraft();
                  part = draft.part;
                  query.text = draft.query;
                  remember();
                }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('part-$part'),
                initialValue: part,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '표준부품'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('전체 부품')),
                  ...parts.map(
                    (p) => DropdownMenuItem(value: p, child: Text(p)),
                  ),
                ],
                onChanged: (value) => setState(() {
                  part = value ?? '';
                  remember();
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('support-query'),
                controller: query,
                maxLength: 1000,
                onChanged: (_) => setState(remember),
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: '증상 또는 부품 검색',
                  hintText: '예) 시동이 걸리지 않아요, 제동 소음',
                  helperText: '입력하면 바로 검색합니다. 질문 저장은 기록만 보관합니다.',
                  helperMaxLines: 2,
                  suffixIcon: query.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '검색어 지우기',
                          onPressed: () => setState(() {
                            query.clear();
                            remember();
                          }),
                          icon: const Icon(Icons.clear),
                        ),
                ),
              ),
              if (ref
                  .watch(adaptiveRuntimeProvider)
                  .installedModels
                  .isNotEmpty) ...[
                TextButton.icon(
                  key: const ValueKey('run-hybrid-search'),
                  onPressed: embeddingBusy || query.text.trim().isEmpty
                      ? null
                      : searchHybrid,
                  icon: const Icon(Icons.manage_search),
                  label: Text(embeddingBusy ? '로컬 임베딩 검색 중…' : '임베딩·키워드 혼합 검색'),
                ),
                if (currentHybrid != null)
                  Text(
                    currentHybrid.mode == 'hybrid'
                        ? '차량·부품 적용조건 확인 후 혼합 검색 · 원문 근거 표시'
                        : '임베딩 검색을 사용할 수 없어 키워드 검색으로 표시합니다.',
                  ),
              ],
              if (query.text.trim().isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '문서 근거 ${evidence.length}건 · 관련 이력 ${records.length}건',
                    key: const ValueKey('support-result-count'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (evidence.isEmpty)
                  note(
                    '일치하는 등록 근거가 없습니다. 부품 선택을 확인하거나 ‘시동’, ‘소음’처럼 짧은 증상으로 검색해 주세요.',
                  ),
                for (final e in evidence.take(2))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${e.title} · ${e.location}'),
                    subtitle: Text(
                      e.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text('${e.title} · ${e.location}'),
                        content: SingleChildScrollView(
                          child: SelectableText(e.text),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('닫기'),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  FilledButton(
                    onPressed: () {
                      remember();
                      context.go(
                        Uri(
                          path: '/vision',
                          queryParameters: {
                            'vehicle': v.id,
                            if (part.isNotEmpty) 'part': part,
                          },
                        ).toString(),
                      );
                    },
                    child: const Text('현장 촬영·부품 지정'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      remember();
                      context.go(
                        Uri(
                          path: '/entry',
                          queryParameters: {
                            'vehicle': v.id,
                            if (part.isNotEmpty) 'part': part,
                            if (linkedInspection != null)
                              'inspection': linkedInspection.id,
                          },
                        ).toString(),
                      );
                    },
                    child: const Text('정비 결과 기록'),
                  ),
                  OutlinedButton(
                    onPressed: query.text.trim().isEmpty || savingQuestion
                        ? null
                        : saveQuestion,
                    child: Text(savingQuestion ? '저장 중…' : '질문 기록 저장'),
                  ),
                  OutlinedButton(
                    onPressed: () => context.go('/plans?vehicle=${v.id}'),
                    child: const Text('연간 정비계획'),
                  ),
                  OutlinedButton(
                    onPressed: () => context.go('/vehicles/${v.id}'),
                    child: const Text('차량 상세'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '정비 문서 근거',
          subtitle: '${v.model} · 표준부품 및 입력 키워드로 검색 · 상위 5건',
          action: TextButton(
            onPressed: () => showEvidenceEditor(context, s, v.model, part),
            child: const Text('근거 등록'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              note(
                s.supportLibrary.knowledge.concepts.isEmpty
                    ? '등록한 문서에서 검색한 원문과 위치를 표시합니다. 자동 생성 답변은 제공하지 않습니다.'
                    : '원문 인용과 위치를 표시합니다. 원문의 숫자는 적용 주기 판정이 아닙니다. 적용 수치는 아래 등록 주기·부대 선택 기준에서만 확인합니다.',
              ),
              const SizedBox(height: 12),
              if (evidence.isEmpty) empty('이 차종과 검색 조건에 맞는 등록 근거가 없습니다.'),
              if (ref
                  .watch(adaptiveRuntimeProvider)
                  .installedModels
                  .any((m) => m.id == 'qwen3-0.6b-q4_0')) ...[
                const Text(
                  '선택 LLM 시험 · 실기기 사양 기준 미확정. 검증된 원문 문장만 추출하며 교환 수치는 등록 규칙에서 확인합니다.',
                ),
                TextButton(
                  onPressed:
                      summaryBusy ||
                          evidence.length < 2 ||
                          !ref
                              .watch(adaptiveRuntimeProvider)
                              .generationTrialAvailable
                      ? null
                      : () => summarize(evidence),
                  child: Text(summaryBusy ? '원문 요약 검증 중…' : '근거 2개로 짧은 요약 시험'),
                ),
                if (summaryKey == searchKey(s) && summary != null)
                  if (summary!.mode == 'extractive_summary')
                    for (final e in summary!.excerpts)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(e.quote),
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: Text(
                                  '${summarySources[e.citation]!.title} · ${summarySources[e.citation]!.location}',
                                ),
                                content: SingleChildScrollView(
                                  child: SelectableText(
                                    summarySources[e.citation]!.text,
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c),
                                    child: const Text('닫기'),
                                  ),
                                ],
                              ),
                            ),
                            child: Text(
                              '인용 원문: ${summarySources[e.citation]!.sourceRef?['file'] ?? summarySources[e.citation]!.title} · ${summarySources[e.citation]!.location}',
                            ),
                          ),
                        ],
                      )
                  else
                    const Text(
                      '요약을 채택하지 않았습니다. 아래 원문 근거와 등록 주기를 확인해 주세요. (retrieval_only)',
                    ),
              ],
              for (final e in evidence)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.title} · ${e.location}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${e.model} · ${standardPart(e.part)} · ${e.symptoms}',
                        style: const TextStyle(color: muted),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(e.text),
                      if (e.conceptId != null)
                        Text(
                          '원문 조건: ${evidenceCondition(e, s.supportLibrary.knowledge).label}',
                        ),
                      TextButton(
                        onPressed: () => deleteEvidence(context, s, e),
                        child: const Text('등록 근거 삭제'),
                      ),
                      const Divider(),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (s.supportLibrary.knowledge.concepts.isNotEmpty) ...[
          KnowledgePanel(store: s, vehicleId: v.id),
          const SizedBox(height: 16),
        ],
        Panel(
          title: '잔여 정비거리',
          subtitle: 'R = max(0, 권장 주기 − 마지막 교환 이후 주행거리)',
          action: TextButton(
            onPressed: () => showRuleEditor(context, s, v.id, part),
            child: const Text('주기·교환 기준 등록'),
          ),
          child: rules.isEmpty
              ? empty('등록된 정비 주기가 없습니다. 확인한 지침의 주기와 마지막 교환 계기를 등록해 주세요.')
              : Column(
                  children: [
                    if (rules.any((r) => r.templateId != null))
                      TextButton.icon(
                        key: const ValueKey('service-as-of'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: evaluationAt ?? s.clock(),
                            firstDate: DateTime(2000),
                            lastDate: s.clock(),
                          );
                          if (picked != null && mounted) {
                            setState(
                              () => evaluationAt =
                                  picked.year == s.clock().year &&
                                      picked.month == s.clock().month &&
                                      picked.day == s.clock().day
                                  ? s.clock()
                                  : DateTime(
                                      picked.year,
                                      picked.month,
                                      picked.day,
                                      23,
                                      59,
                                      59,
                                    ),
                            );
                          }
                        },
                        icon: const Icon(Icons.calendar_today),
                        label: Text('기준일 ${day(evaluationAt ?? s.clock())}'),
                      ),
                    if (evaluationAt != null)
                      TextButton(
                        onPressed: () => setState(() => evaluationAt = null),
                        child: const Text('현재 기준으로 돌아가기'),
                      ),
                    for (final r in rules)
                      RuleTile(rule: r, store: s, asOf: evaluationAt),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '관련 정비 이력',
          subtitle: '${v.id} · 부품·증상 조건 · 최근 최대 12건',
          child: records.isEmpty
              ? empty('일치하는 차량 정비 이력이 없습니다.')
              : Column(
                  children: [
                    for (final r in records)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${standardPart(r.part)} · ${r.date}'),
                        subtitle: Text(
                          '${part.isNotEmpty && s.supportLibrary.knowledge.conceptFor(part) != null && r.confirmedConceptId == null ? '부품 연결 미확인 후보 · ' : ''}${r.description}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/records/${r.id}'),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '현장 점검 연결',
          subtitle: '같은 차량·부품의 촬영 기록 · 수동 지정 · 최대 6건',
          child: inspections.isEmpty
              ? empty('연결된 현장 기록이 없습니다.')
              : Column(
                  children: [
                    for (final i in inspections)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${standardPart(i.area)} · ${i.created.substring(0, 10)}',
                        ),
                        subtitle: Text(i.note),
                        onTap: () => context.go(
                          '/vision?vehicle=${v.id}&session=${i.id}',
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        if (s.questions.any((q) => q['vehicleId'] == v.id))
          Panel(
            title: '저장한 질문',
            child: Column(
              children: [
                for (final q
                    in s.questions.where((q) => q['vehicleId'] == v.id).take(6))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(q['question']),
                    subtitle: Text(q['created'].toString().substring(0, 10)),
                    onTap: () => setState(() {
                      query.text = q['question'];
                      part = standardPart(q['standardPart'] as String? ?? '');
                    }),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class BlockingMaintenanceLinks extends StatelessWidget {
  const BlockingMaintenanceLinks({
    required this.rule,
    required this.store,
    this.asOf,
    super.key,
  });
  final MaintenanceRule rule;
  final AppStore store;
  final DateTime? asOf;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (asOf != null &&
          store.serviceDistance(rule, asOf: asOf).blockingRecordIds.isNotEmpty)
        const Text('과거 기준 조회입니다. 기록 수정은 현재 기준으로 돌아가 확인해 주세요.'),
      if (asOf == null)
        for (final id in store.serviceDistance(rule).blockingRecordIds)
          if (store.records
                  .where((r) => r.id == id && r.vehicleId == rule.vehicleId)
                  .firstOrNull
              case final record?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${record.date} · ${record.part}'),
              subtitle: Text(
                '교환 여부: ${replacementStatusLabel(record.replacementCompleted)}',
              ),
              trailing: TextButton(
                key: ValueKey('resolve-maintenance-$id'),
                onPressed: () => context.go(
                  Uri(
                    path: '/entry',
                    queryParameters: {'record': id},
                  ).toString(),
                ),
                child: const Text('확인하기'),
              ),
            ),
    ],
  );
}

class RuleTile extends StatelessWidget {
  const RuleTile({
    required this.rule,
    required this.store,
    this.asOf,
    super.key,
  });
  final MaintenanceRule rule;
  final AppStore store;
  final DateTime? asOf;
  @override
  Widget build(BuildContext context) {
    final result = store.serviceDistance(rule, asOf: asOf);
    final criteria = store.selectedRuleCriteria(rule, asOf: asOf);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: rule.templateId != null
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.start,
        children: [
          if (rule.templateId != null) ...[
            Text(
              criteria['reason'] != null
                  ? '적용 주기 판정: ${criteria['reason']}'
                  : '적용 주기(등록 규칙·부대 설정): 거리 ${criteria['km'] ?? '확인 불가'} km · 기간 ${criteria['months'] ?? '확인 불가'}개월',
            ),
            Text(
              '${rule.part} · 적용 기준 ${result.policy == 'normal'
                  ? '일반'
                  : result.policy == 'severe'
                  ? '가혹'
                  : '미선택'}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            Text(dualServiceSummary(result)),
            Text(
              '기준시각: ${(asOf ?? store.clock()).toIso8601String()}\n교환일 ${result.baselineDate ?? '미확인'} · 교환 계기 ${result.baselineKm ?? '미확인'}\n운용 관측시각 ${result.observedAt ?? '미확인'}',
            ),
          ] else if (asOf != null) ...[
            const Text('기존 수동 거리 주기 · 과거 기준 조회 확인 불가'),
          ] else ...[
            Text(
              '${standardPart(rule.part)} · ${result.remainingKm == null
                  ? '계산 보류'
                  : result.remainingKm == 0
                  ? '정비 주기 도달'
                  : '잔여 ${number(result.remainingKm!)} km'}',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            Text(
              '주기 ${number(rule.intervalKm!)} km · 마지막 교환 ${result.baselineDate ?? rule.baselineDate} / ${number(result.baselineKm ?? rule.baselineKm!)} km',
            ),
          ],
          Text(
            rule.templateId == null
                ? '근거: ${rule.source}'
                : result.sourceRef == null
                ? '판정 적용 보류 · 일반·가혹 원문은 반입 자료에서 확인하세요.'
                : '판정 근거: ${result.sourceRef!['file']} · PDF ${result.sourceRef!['page']}쪽 · ${result.sourceRef!['location']}',
            style: const TextStyle(color: muted),
          ),
          if (result.recordId != null)
            TextButton(
              onPressed: () => context.go('/records/${result.recordId}'),
              child: const Text('교환 완료 기록 보기'),
            ),
          if (result.reason != null && rule.templateId == null)
            note(result.reason!, color: Colors.orange),
          BlockingMaintenanceLinks(rule: rule, store: store, asOf: asOf),
          Wrap(
            spacing: 12,
            children: [
              TextButton(
                onPressed: () => showRuleEditor(
                  context,
                  store,
                  rule.vehicleId,
                  rule.part,
                  existing: rule,
                ),
                child: const Text('기준 수정'),
              ),
              TextButton(
                onPressed: () => deleteRule(context, store, rule),
                child: const Text('주기 삭제'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class MaintenancePlanScreen extends ConsumerStatefulWidget {
  const MaintenancePlanScreen({this.vehicleId, super.key});
  final String? vehicleId;
  @override
  ConsumerState<MaintenancePlanScreen> createState() => _PlanState();
}

class _PlanState extends ConsumerState<MaintenancePlanScreen> {
  int? year;
  late String? vehicle = widget.vehicleId;
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    year ??= s.clock().year;
    if (vehicle != null && !s.vehicles.any((v) => v.id == vehicle)) {
      vehicle = null;
    }
    final rules =
        s.supportLibrary.rules
            .where(
              (r) => vehicle == null
                  ? s.activeVehicles.any((v) => v.id == r.vehicleId)
                  : r.vehicleId == vehicle,
            )
            .toList()
          ..sort(
            (a, b) => (s.serviceDistance(a).remainingKm ?? 1000000000000)
                .compareTo(s.serviceDistance(b).remainingKm ?? 1000000000000),
          );
    final dates = {for (final r in rules) r.id: s.estimatedServiceDate(r)};
    return ListView(
      children: [
        PageTitle(
          '연간 정비계획',
          '등록 주기와 최근 90일 운용 추세로 차량·부품별 다음 정비 시점을 확인합니다.',
          scopeVehicles: vehicle == null
              ? s.activeVehicles
              : [s.vehicle(vehicle!)],
        ),
        Panel(
          title: '계획 범위',
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: vehicle ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '차량'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('전체 차량')),
                  ...s.vehicles.map(
                    (v) => DropdownMenuItem(
                      value: v.id,
                      child: Text('${v.id} · ${v.model}'),
                    ),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => vehicle = value == '' ? null : value),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() => year = year! - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '$year년',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    onPressed: () => setState(() => year = year! + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              note(
                '예상일은 최근 운용 증가량을 일평균으로 환산한 참고값입니다. 7일 이상 관측·2건 이상 기록·30일 이내 최신 기록이 필요합니다. 다음 1회 정비만 표시하며 실제 교환 후 기준을 갱신해 주세요.',
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  var target = vehicle;
                  target ??= await showDialog<String>(
                    context: context,
                    builder: (dialogContext) => SimpleDialog(
                      title: const Text('정비 주기를 등록할 차량'),
                      children: [
                        for (final v in s.vehicles)
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(dialogContext, v.id),
                            child: Text('${v.id} · ${v.model}'),
                          ),
                      ],
                    ),
                  );
                  if (target != null && context.mounted) {
                    await showRuleEditor(context, s, target, '');
                  }
                },
                child: const Text('정비 주기 등록'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (rules.isEmpty) empty('등록된 정비 주기가 없습니다.'),
        for (var month = 1; month <= 12; month++)
          if (rules.any(
            (r) => dates[r.id]?.year == year && dates[r.id]?.month == month,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                title: '$year년 $month월',
                child: Column(
                  children: [
                    for (final r in rules.where(
                      (r) =>
                          dates[r.id]?.year == year &&
                          dates[r.id]?.month == month,
                    ))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${r.vehicleId} · ${standardPart(r.part)}'),
                        subtitle: Text(
                          '예상 ${day(dates[r.id]!)} · 잔여 ${number(s.serviceDistance(r).remainingKm!)} km',
                        ),
                        onTap: () =>
                            context.go(supportUrl(r.vehicleId, r.part)),
                      ),
                  ],
                ),
              ),
            ),
        Panel(
          title: '정비 주기 전체',
          subtitle: '계산 보류 및 선택 연도 밖의 항목도 포함합니다.',
          child: Column(
            children: [
              for (final r in rules) ...[
                if (r.templateId != null)
                  RuleTile(rule: r, store: s)
                else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${r.vehicleId} · ${standardPart(r.part)}'),
                    subtitle: Text(
                      s.serviceDistance(r).reason ??
                          '잔여 ${number(s.serviceDistance(r).remainingKm!)} km · ${dates[r.id] == null ? '예상 날짜는 운용 기록 축적 후 표시됩니다.' : '다음 예상일 ${day(dates[r.id]!)}'}',
                    ),
                    onTap: () => context.go(supportUrl(r.vehicleId, r.part)),
                  ),
                  BlockingMaintenanceLinks(rule: r, store: s),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Local source registration; a page/section reference is mandatory.
Future<void> showEvidenceEditor(
  BuildContext context,
  AppStore store,
  String model,
  String part,
) async {
  final fields = {
    '차종': TextEditingController(text: model),
    '표준부품명': TextEditingController(text: part),
    '증상 키워드': TextEditingController(),
    '문서명·개정판': TextEditingController(),
    '원문 위치(쪽·절)': TextEditingController(),
    '원문 구간': TextEditingController(),
  };
  await _editor(context, '정비 문서 근거 등록', fields, () async {
    final e = MaintenanceEvidence(
      id: store.newId('DOC'),
      model: fields['차종']!.text.trim(),
      part: standardPart(fields['표준부품명']!.text),
      symptoms: fields['증상 키워드']!.text.trim(),
      title: fields['문서명·개정판']!.text.trim(),
      location: fields['원문 위치(쪽·절)']!.text.trim(),
      text: fields['원문 구간']!.text.trim(),
    );
    await store.updateSupportLibrary(
      (latest) => latest.copyWith(
        evidence: [...latest.evidence, e],
        rules: latest.rules,
      ),
    );
  });
  // Dialog closing animations can still reference their controllers.
}

Future<void> showRuleEditor(
  BuildContext context,
  AppStore store,
  String vehicle,
  String part, {
  MaintenanceRule? existing,
}) async {
  if (existing?.templateId != null) {
    final template = store.supportLibrary.knowledge.templates.singleWhere(
      (t) => t['id'] == existing!.templateId,
    );
    await showKnowledgeRuleEditor(context, store, vehicle, template);
    return;
  }
  final completed =
      store
          .history(vehicle)
          .where(
            (r) =>
                r.replacementCompleted == true &&
                r.odometerKm != null &&
                standardPart(r.part) == standardPart(part),
          )
          .toList()
        ..sort((a, b) {
          final c = b.date.compareTo(a.date);
          return c != 0 ? c : b.odometerKm!.compareTo(a.odometerKm!);
        });
  final latest = completed.firstOrNull;
  final fields = {
    '표준부품명': TextEditingController(text: existing?.part ?? part),
    '권장 정비 주기(km)': TextEditingController(
      text: existing?.intervalKm.toString(),
    ),
    '마지막 교환 계기(km)': TextEditingController(
      text: (existing?.baselineKm ?? latest?.odometerKm)?.toString(),
    ),
    '마지막 교환일(YYYY-MM-DD)': TextEditingController(
      text: existing?.baselineDate ?? latest?.date,
    ),
    '주기 근거(문서명·쪽)': TextEditingController(text: existing?.source),
  };
  await _editor(
    context,
    '$vehicle 정비 주기 등록',
    fields,
    () async {
      final current = store.supportLibrary;
      final p = standardPart(fields['표준부품명']!.text);
      final r = MaintenanceRule(
        id: existing?.id ?? store.newId('RULE'),
        vehicleId: vehicle,
        part: p,
        intervalKm: parseKm(fields['권장 정비 주기(km)']!.text)!,
        baselineKm: parseKm(fields['마지막 교환 계기(km)']!.text)!,
        baselineDate: fields['마지막 교환일(YYYY-MM-DD)']!.text.trim(),
        source: fields['주기 근거(문서명·쪽)']!.text.trim(),
      );
      if (current.rules.any(
        (rule) =>
            rule.id != existing?.id &&
            rule.vehicleId == vehicle &&
            standardPart(rule.part) == p,
      )) {
        throw ArgumentError('이 부품의 주기가 이미 있습니다. 기존 기준을 수정해 주세요.');
      }
      await store.updateSupportLibrary(
        (latest) => latest.copyWith(
          evidence: latest.evidence,
          rules: [...latest.rules.where((r) => r.id != existing?.id), r],
        ),
      );
    },
    maxDistance: store.vehicle(vehicle).distance,
    firstDate: DateTime(store.vehicle(vehicle).year),
    lastDate: store.clock(),
  );
}

int? parseKm(String value) {
  final text = value.trim();
  if (!RegExp(r'^(\d+|\d{1,3}(,\d{3})+)$').hasMatch(text)) return null;
  return int.tryParse(text.replaceAll(',', ''));
}

Future<void> deleteEvidence(
  BuildContext context,
  AppStore store,
  MaintenanceEvidence e,
) async {
  await _deleteWithUndo(
    context,
    '${e.title} · ${e.location}',
    remove: () => store.updateSupportLibrary(
      (latest) => latest.copyWith(
        evidence: latest.evidence.where((item) => item.id != e.id).toList(),
        rules: latest.rules,
      ),
    ),
    undo: () => store.updateSupportLibrary(
      (latest) => latest.copyWith(
        evidence: latest.evidence.any((item) => item.id == e.id)
            ? latest.evidence
            : [...latest.evidence, e],
        rules: latest.rules,
      ),
    ),
  );
}

Future<void> deleteRule(
  BuildContext context,
  AppStore store,
  MaintenanceRule rule,
) => _deleteWithUndo(
  context,
  '${rule.vehicleId} · ${rule.part} 정비 주기',
  remove: () => store.updateSupportLibrary(
    (latest) => latest.copyWith(
      evidence: latest.evidence,
      rules: latest.rules.where((r) => r.id != rule.id).toList(),
    ),
  ),
  undo: () => store.updateSupportLibrary((latest) {
    if (latest.rules.any(
      (r) =>
          r.vehicleId == rule.vehicleId &&
          standardPart(r.part) == standardPart(rule.part),
    )) {
      throw ArgumentError('같은 부품의 정비 주기가 이미 있습니다. 현재 기준을 확인해 주세요.');
    }
    return latest.copyWith(
      evidence: latest.evidence,
      rules: [...latest.rules, rule],
    );
  }),
);

Future<void> _deleteWithUndo(
  BuildContext context,
  String label, {
  required Future<void> Function() remove,
  required Future<void> Function() undo,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('삭제 확인'),
      content: Text('$label\n삭제하시겠습니까?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('삭제'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await remove();
    if (!messenger.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('$label 삭제됨'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: '실행 취소',
          onPressed: () async {
            try {
              await undo();
              if (!messenger.mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('삭제를 되돌렸습니다.')),
              );
            } catch (_) {
              if (!messenger.mounted) return;
              messenger.showSnackBar(
                const SnackBar(content: Text('복구하지 못했습니다. 현재 등록 자료를 확인해 주세요.')),
              );
            }
          },
        ),
      ),
    );
  } catch (_) {
    if (!messenger.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('삭제하지 못했습니다. 다시 시도해 주세요.')),
    );
  }
}

Future<void> _editor(
  BuildContext context,
  String title,
  Map<String, TextEditingController> fields,
  Future<void> Function() save, {
  int? maxDistance,
  DateTime? firstDate,
  DateTime? lastDate,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SupportEditor(
    title: title,
    fields: fields,
    save: save,
    maxDistance: maxDistance,
    firstDate: firstDate,
    lastDate: lastDate,
  ),
);

class _SupportEditor extends StatefulWidget {
  const _SupportEditor({
    required this.title,
    required this.fields,
    required this.save,
    this.maxDistance,
    this.firstDate,
    this.lastDate,
  });
  final String title;
  final Map<String, TextEditingController> fields;
  final Future<void> Function() save;
  final int? maxDistance;
  final DateTime? firstDate, lastDate;
  @override
  State<_SupportEditor> createState() => _EditorState();
}

class _EditorState extends State<_SupportEditor> {
  final form = GlobalKey<FormState>();
  final fieldKeys = <String, GlobalKey>{};
  final focusNodes = <String, FocusNode>{};
  String? error;
  bool saving = false;
  String? validate(String label, String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return label == '증상 키워드' ? null : '$label 항목을 입력해 주세요.';
    if (label.contains('(km)')) {
      final km = parseKm(value);
      if (km == null) return '숫자를 입력해 주세요. 예: 10,000';
      if (label.startsWith('권장') && (km <= 0 || km > 1000000)) {
        return '정비 주기는 1~1,000,000 km로 입력해 주세요.';
      }
      if (label.startsWith('마지막') &&
          (km < 0 || km > (widget.maxDistance ?? 1000000000000))) {
        return '교환 계기는 현재 누적 ${number(widget.maxDistance ?? 0)} km 이하여야 합니다.';
      }
    }
    if (label.contains('YYYY-MM-DD')) {
      final date = DateTime.tryParse(value);
      if (date == null || date.toIso8601String().substring(0, 10) != value) {
        return '날짜를 YYYY-MM-DD 형식으로 입력해 주세요.';
      }
      if (date.isAfter(widget.lastDate!) || date.isBefore(widget.firstDate!)) {
        return '출고연도부터 오늘 사이 날짜를 선택해 주세요.';
      }
    }
    return null;
  }

  @override
  void dispose() {
    for (final node in focusNodes.values) {
      node.dispose();
    }
    for (final c in widget.fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        child: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in widget.fields.entries)
                  Padding(
                    key: fieldKeys.putIfAbsent(entry.key, () => GlobalKey()),
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextFormField(
                      key: ValueKey(entry.key),
                      focusNode: focusNodes.putIfAbsent(
                        entry.key,
                        () => FocusNode(),
                      ),
                      controller: entry.value,
                      enabled: !saving,
                      minLines: entry.key == '원문 구간' ? 4 : 1,
                      maxLines: entry.key == '원문 구간' ? 8 : 1,
                      keyboardType: entry.key.contains('(km)')
                          ? TextInputType.number
                          : entry.key.contains('YYYY-MM-DD')
                          ? TextInputType.datetime
                          : entry.key == '원문 구간'
                          ? TextInputType.multiline
                          : TextInputType.text,
                      validator: (value) => validate(entry.key, value),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      maxLength: entry.key.contains('(km)')
                          ? 18
                          : entry.key.contains('YYYY-MM-DD')
                          ? 10
                          : entry.key == '원문 구간'
                          ? 10000
                          : entry.key.contains('근거') || entry.key == '증상 키워드'
                          ? 1000
                          : 300,
                      decoration: InputDecoration(
                        labelText:
                            '${entry.key}${entry.key == '증상 키워드' ? ' (선택)' : ' *'}',
                        errorMaxLines: 3,
                        helperText: entry.key.startsWith('마지막 교환 계기')
                            ? '현재 누적 ${number(widget.maxDistance ?? 0)} km'
                            : null,
                        suffixIcon: !entry.key.contains('YYYY-MM-DD')
                            ? null
                            : IconButton(
                                tooltip: '교환일 선택',
                                icon: const Icon(Icons.calendar_month_outlined),
                                onPressed: saving
                                    ? null
                                    : () async {
                                        final first = widget.firstDate!;
                                        final last = widget.lastDate!;
                                        final entered = DateTime.tryParse(
                                          entry.value.text,
                                        );
                                        final initial =
                                            entered != null &&
                                                !entered.isBefore(first) &&
                                                !entered.isAfter(last)
                                            ? entered
                                            : last;
                                        final date = await showDatePicker(
                                          context: context,
                                          initialDate: initial,
                                          firstDate: first,
                                          lastDate: last,
                                        );
                                        if (date != null && mounted) {
                                          setState(
                                            () => entry.value.text = date
                                                .toIso8601String()
                                                .substring(0, 10),
                                          );
                                        }
                                      },
                              ),
                      ),
                    ),
                  ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: saving
              ? null
              : () async {
                  if (!form.currentState!.validate()) {
                    final label = widget.fields.keys.firstWhere(
                      (key) => validate(key, widget.fields[key]!.text) != null,
                    );
                    focusNodes[label]?.requestFocus();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      final target = fieldKeys[label]?.currentContext;
                      if (mounted && target != null) {
                        Scrollable.ensureVisible(target, alignment: .2);
                      }
                    });
                    return;
                  }
                  setState(() {
                    saving = true;
                    error = null;
                  });
                  try {
                    await widget.save();
                    if (context.mounted) {
                      setState(() => saving = false);
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        saving = false;
                        error = e is ArgumentError
                            ? e.message.toString()
                            : '입력 형식·필수값·숫자 범위를 확인해 주세요.';
                      });
                    }
                  }
                },
          child: Text(saving ? '저장 중…' : '저장'),
        ),
      ],
    ),
  );
}
