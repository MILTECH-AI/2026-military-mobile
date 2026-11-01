import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/store.dart';
import 'components.dart';
import 'support.dart';
import 'knowledge_tools.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(storeProvider);
    final vehicles = s.activeVehicles;
    final ids = vehicles.map((v) => v.id).toSet();
    final demo = s.registeredVehicles.isEmpty;
    final rules = s.supportLibrary.rules
        .where((r) => ids.contains(r.vehicleId))
        .toList();
    final assessments = {for (final r in rules) r.id: s.serviceDistance(r)};
    final ordered = [...rules]
      ..sort((a, b) {
        final av = assessments[a.id]!, bv = assessments[b.id]!;
        final c = (av.remainingKm ?? -1).compareTo(bv.remainingKm ?? -1);
        return c != 0
            ? c
            : '${a.vehicleId}|${a.part}'.compareTo('${b.vehicleId}|${b.part}');
      });
    final withoutRules = vehicles
        .where((v) => !rules.any((r) => r.vehicleId == v.id))
        .toList();
    final due = assessments.values.where((r) => r.remainingKm == 0).length;
    final blocked = assessments.values.where((r) => r.reason != null).length;
    final records = s.records.where((r) => ids.contains(r.vehicleId)).toList();
    final models = vehicles.map((v) => v.model).toSet();
    final documentCount = s.supportLibrary.evidence
        .where((e) => models.contains(e.model))
        .length;

    final nextMaintenancePanel = Panel(
      title: '다음으로 확인할 정비',
      subtitle: '기준 확인이 필요한 항목, 잔여 거리 순 · 최대 5건',
      action: TextButton(
        onPressed: () => context.go('/plans'),
        child: const Text('계획 전체 보기'),
      ),
      child: ordered.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  demo
                      ? '등록된 정비 주기가 없습니다. 실사용 준비에서 실제 차량과 확인한 주기를 등록해 주세요.'
                      : '아직 정비 주기가 없습니다. 확인한 지침의 주기와 마지막 교환 기준을 등록해 주세요.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => context.go(demo ? '/setup' : '/plans'),
                  child: Text(demo ? '실사용 준비 시작' : '정비 주기 등록하기'),
                ),
              ],
            )
          : Column(
              children: [
                for (final rule in ordered.take(5)) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${rule.vehicleId} · ${standardPart(rule.part)}',
                    ),
                    subtitle: Text(
                      rule.templateId != null
                          ? dualServiceSummary(assessments[rule.id]!)
                          : assessments[rule.id]!.reason ??
                                (assessments[rule.id]!.remainingKm == 0
                                    ? '정비 주기에 도달했습니다. 작업 결과를 기록하고 다음 기준을 확인해 주세요.'
                                    : '잔여 ${number(assessments[rule.id]!.remainingKm!)} km · 근거 ${rule.source}'),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        context.go(supportUrl(rule.vehicleId, rule.part)),
                  ),
                  BlockingMaintenanceLinks(rule: rule, store: s),
                ],
              ],
            ),
    );

    return ListView(
      children: [
        const PageTitle('종합 현황', '준비 상태를 확인하고, 차량별 점검·정비와 다음 계획으로 이어갑니다.'),
        note(
          demo
              ? '예제 데이터 보기 · 실제 차량을 등록하면 등록 차량의 업무 현황으로 전환됩니다.'
              : '등록 차량 ${vehicles.length}대 기준 · 예제 차량은 업무 현황과 집계에서 제외됩니다.',
        ),
        const SizedBox(height: 16),
        Panel(
          title: demo ? '처음이라면 실사용 준비부터' : '차량과 자료 준비',
          subtitle:
              '차량 ${s.registeredVehicles.length}대 등록 · 문서 근거 $documentCount건 · 정비 주기 ${rules.length}건',
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: () => context.go('/setup'),
                child: const Text('실사용 준비·차량 등록'),
              ),
              Text(
                demo
                    ? '차량 → 정비 근거 → 확인한 교환 주기 순서로 준비해 주세요.'
                    : '차량을 추가하거나 정비 근거와 교환 주기를 보완할 수 있습니다.',
                style: const TextStyle(color: muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, c) {
            final columns = c.maxWidth < 700 ? 2 : 4;
            final items = [
              (demo ? '예제 차량' : '등록 차량', vehicles.length, '대', ink),
              ('주기 도달', due, '항목', const Color(0xFFD24C39)),
              ('기준 확인 필요', blocked, '항목', const Color(0xFFB77912)),
              ('주기 미등록', withoutRules.length, '대', muted),
            ];
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final item in items)
                  SizedBox(
                    width: (c.maxWidth - (columns - 1) * 12) / columns,
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: line),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.$1,
                            style: const TextStyle(color: muted, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${number(item.$2)}${item.$3}',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: item.$2 == 0 ? muted : item.$4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        if (!demo) ...[nextMaintenancePanel, const SizedBox(height: 16)],
        Panel(
          title: '정비 업무 시작',
          subtitle: '차량 선택 → 점검·근거 확인 → 작업 기록 → 완료·계획',
          child: LayoutBuilder(
            builder: (context, c) {
              final columns = c.maxWidth < 850 ? 2 : 4;
              final items = [
                (
                  '1',
                  '차량 현황',
                  '작업할 차량과 이력 선택',
                  '/vehicles',
                  Icons.directions_car_outlined,
                ),
                (
                  '2',
                  'AI 정비지원',
                  '점검 사진·등록 근거 확인',
                  '/support',
                  Icons.manage_search_outlined,
                ),
                (
                  '3',
                  '데이터 입력',
                  '정비 결과·교환 계기 기록',
                  '/entry',
                  Icons.edit_note_outlined,
                ),
                (
                  '4',
                  '연간 정비계획',
                  '완료 후 다음 정비거리 확인',
                  '/plans',
                  Icons.event_note_outlined,
                ),
              ];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final item in items)
                    SizedBox(
                      width: (c.maxWidth - (columns - 1) * 12) / columns,
                      child: OutlinedButton(
                        onPressed: () => context.go(item.$4),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.all(14),
                          alignment: Alignment.centerLeft,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(item.$5, color: green, size: 22),
                                const Spacer(),
                                Text(
                                  item.$1,
                                  style: const TextStyle(color: muted),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              item.$2,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: ink,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.$3,
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        if (demo) nextMaintenancePanel,
        const SizedBox(height: 16),
        Panel(
          title: '최근 정비 기록',
          subtitle: '현재 조회 범위의 최근 3건',
          action: TextButton(
            onPressed: () => context.go('/records'),
            child: const Text('기록 전체 보기'),
          ),
          child: records.isEmpty
              ? const Text('저장된 정비 기록이 없습니다. 점검 후 작업 결과를 기록해 주세요.')
              : Column(
                  children: [
                    for (final r in records.take(3))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${r.vehicleId} · ${r.part}'),
                        subtitle: Text(
                          '${r.date} · ${r.replacementCompleted == true
                              ? '교환 완료'
                              : r.replacementCompleted == false
                              ? '점검·수리'
                              : '과거 기록'}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/records/${r.id}'),
                      ),
                  ],
                ),
        ),
        if (demo) ...[
          const SizedBox(height: 16),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            child: ExpansionTile(
              title: const Text('예제 분석 보기'),
              subtitle: const Text('합성 데이터 모델 · 실제 차량의 고장 판정이 아닙니다.'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: StatusRing(vehicles),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
