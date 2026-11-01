import 'dart:io';

import 'package:flutter/material.dart';

import '../data/store.dart';
import 'components.dart';
import 'data_tools.dart' show NativeBackupFiles;

Future<String?> importKnowledgeFile(
  BuildContext context,
  AppStore store,
) async {
  final path = await NativeBackupFiles.pick();
  if (path == null) return '자료 선택을 취소했습니다.';
  try {
    final file = File(path);
    if (await file.length() > 4000000) {
      throw const FormatException('반입 자료는 4MB 이하여야 합니다.');
    }
    final bundle = KnowledgeBundle.decode(await file.readAsString());
    if (!context.mounted) return null;
    final k = bundle.library.knowledge;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('정비 자료 반입 검토'),
        content: SingleChildScrollView(
          child: Text(
            '부품 개념 ${k.concepts.length}개 · 품번 후보 ${k.skus.length}개\n문서 근거 ${bundle.library.evidence.length}개 · 주기 기준 ${k.templates.length}개\n정비실적 검토 대기 ${k.pending.length}건\n\n검토 대기 실적은 실차 이력·집계·ML 입력에 넣지 않습니다. 품번 적용조건과 차량·지침 연결은 별도로 확인합니다. 현재 기록을 교체하지 않습니다.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('confirm-knowledge-import'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('검토 대기로 반입'),
          ),
        ],
      ),
    );
    if (yes != true) return '자료 반입을 취소했습니다.';
    return await store.importKnowledge(bundle)
        ? '자료를 반입했습니다. 실적은 검토 대기이며 차량 적용조건을 확인해 주세요.'
        : '동일한 자료가 이미 반입되어 있습니다. 중복 저장하지 않았습니다.';
  } finally {
    await NativeBackupFiles.release(path);
  }
}

String cycleDescription(Map p) =>
    '${p['km'] == null ? '거리 수치 없음' : '${p['km']} km'} · ${p['months'] == null ? '기간 수치 없음' : '${p['months']}개월'}';

String dualServiceSummary(ServiceDistance result) => [
  '거리: ${result.remainingKm == null
      ? (result.reason ?? '확인 불가')
      : result.remainingKm == 0
      ? '도래'
      : '잔여 ${number(result.remainingKm!)} km'}',
  '기간: ${result.remainingDays == null
      ? (result.calendarReason ?? '확인 불가')
      : result.remainingDays! <= 0
      ? '도래 (${day(result.calendarDue!)})'
      : '${day(result.calendarDue!)}까지 ${result.remainingDays}일'}',
  result.firstDue,
].join('\n');

class KnowledgePanel extends StatelessWidget {
  const KnowledgePanel({required this.store, this.vehicleId, super.key});
  final AppStore store;
  final String? vehicleId;
  @override
  Widget build(BuildContext context) {
    final k = store.supportLibrary.knowledge;
    return Panel(
      title: '반입 자료·부대 적용 기준',
      subtitle: '실적은 출처 확인 전 검토 대기 · 품번은 적용조건 확인 전 후보',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (k.templates.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              key: ValueKey('service-policy-${k.choiceAt(store.clock())}'),
              initialValue: k.choiceAt(store.clock()),
              decoration: const InputDecoration(labelText: '부대 적용 기준'),
              items: const [
                DropdownMenuItem(value: 'unselected', child: Text('미선택')),
                DropdownMenuItem(value: 'normal', child: Text('일반')),
                DropdownMenuItem(value: 'severe', child: Text('가혹')),
              ],
              onChanged: (value) async {
                if (value == null) return;
                try {
                  await store.selectServicePolicy(value);
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('적용 기준을 저장하지 못했습니다.')),
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 12),
          ],
          Text(
            '부품 개념 ${k.concepts.length}개 · 품번 후보 ${k.skus.length}개 · 정비실적 검토 대기 ${k.pending.length}건',
          ),
          for (final c in k.concepts) ...[
            const Divider(),
            Text(
              c['name'] as String,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            for (final sku in k.skus.where((s) => s['conceptId'] == c['id']))
              Text(
                '${sku['partNumber']} · ${sku['name']}\n적용 미확정: ${sku['conditions']}\n${sku['sourceRef']['file']} · PDF ${sku['sourceRef']['page']}쪽 · ${sku['sourceRef']['location']}',
              ),
            for (final t in k.templates.where(
              (t) => t['conceptId'] == c['id'],
            )) ...[
              Text(
                '일반: ${cycleDescription(t['normal'] as Map)}\n가혹: ${cycleDescription(t['severe'] as Map)}\n적용조건: ${t['applicabilityNote']}',
              ),
              Text(
                '일반 근거: ${t['normal']['sourceRef']['file']} · PDF ${t['normal']['sourceRef']['page']}쪽\n${t['normal']['note']}\n가혹 근거: ${t['severe']['sourceRef']['file']} · PDF ${t['severe']['sourceRef']['page']}쪽\n${t['severe']['note']}',
              ),
              if (vehicleId != null && !vehicleId!.startsWith('MOCK-'))
                TextButton(
                  onPressed: () =>
                      showKnowledgeRuleEditor(context, store, vehicleId!, t),
                  child: const Text('지침 적용·교환 기준 확인'),
                ),
            ],
          ],
          if (k.pending.isNotEmpty)
            ExpansionTile(
              title: const Text('정비실적 검토 대기'),
              children: [
                for (final p in k.pending)
                  ListTile(
                    title: Text((p['record'] as Map)['part'] as String),
                    subtitle: Text(
                      '교환 여부 미확인 · 차량 연결·실적 출처 미확정\n${p['sourceRef']['file']} · PDF ${p['sourceRef']['page']}쪽',
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

Future<void> showKnowledgeRuleEditor(
  BuildContext context,
  AppStore store,
  String vehicleId,
  Map<String, dynamic> template,
) async {
  final concept = store.supportLibrary.knowledge.concepts.singleWhere(
    (c) => c['id'] == template['conceptId'],
  );
  final old = store.supportLibrary.rules
      .where((r) => r.vehicleId == vehicleId && r.conceptId == concept['id'])
      .firstOrNull;
  final km = TextEditingController(text: old?.baselineKm?.toString() ?? '');
  final date = TextEditingController(text: old?.baselineDate ?? '');
  var checked = old?.applicabilityConfirmed ?? false;
  String? error;
  final form = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text('${concept['name']} · 지침 적용·교환 기준'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '일반: ${cycleDescription(template['normal'] as Map)}\n가혹: ${cycleDescription(template['severe'] as Map)}\n${template['applicabilityNote']}\n품번 후보를 실제 장착품으로 확정하지 않습니다.',
                ),
                CheckboxListTile(
                  value: checked,
                  onChanged: (v) => set(() => checked = v ?? false),
                  title: const Text('이 차량의 차종·엔진 사양과 지침 적용조건을 확인했습니다'),
                ),
                TextFormField(
                  key: const ValueKey('knowledge-baseline-km'),
                  controller: km,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '확인한 마지막 교환 계기(km) · 모르면 비움',
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final n = int.tryParse(v);
                    return n == null ||
                            n < 0 ||
                            n > store.vehicle(vehicleId).distance
                        ? '현재 계기 이하의 확인한 값만 입력해 주세요.'
                        : null;
                  },
                ),
                TextFormField(
                  key: const ValueKey('knowledge-baseline-date'),
                  controller: date,
                  decoration: const InputDecoration(
                    labelText: '확인한 교환일 YYYY-MM-DD · 모르면 비움',
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final d = DateTime.tryParse(v);
                    return d == null ||
                            v != d.toIso8601String().substring(0, 10) ||
                            d.isAfter(store.clock()) ||
                            d.year < store.vehicle(vehicleId).year
                        ? '확인한 유효한 교환일을 입력해 주세요.'
                        : null;
                  },
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('save-knowledge-rule'),
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              final now = store.clock().toIso8601String();
              final r = MaintenanceRule(
                id: old?.id ?? store.newId('RULE'),
                vehicleId: vehicleId,
                part: concept['name'],
                intervalKm: null,
                baselineKm: int.tryParse(km.text.trim()),
                baselineDate: date.text.trim(),
                source: template['normal']['sourceRef']['file'],
                templateId: template['id'],
                conceptId: concept['id'],
                applicabilityConfirmed: checked,
                linkedAt: now,
                baselineConfirmedAt: now,
              );
              try {
                await store.updateSupportLibrary(
                  (s) => s.copyWith(
                    rules: [...s.rules.where((x) => x.id != r.id), r],
                  ),
                );
                if (c.mounted) Navigator.pop(c);
              } catch (_) {
                set(() => error = '저장하지 못했습니다. 같은 부품의 기존 주기와 입력값을 확인해 주세요.');
              }
            },
            child: const Text('확인 상태 저장'),
          ),
        ],
      ),
    ),
  );
  // Dialog controllers can still be used by its closing animation.
}
