import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/store.dart';
import 'components.dart';
import 'support.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({this.vehicleId, super.key});
  final String? vehicleId;
  @override
  ConsumerState<SetupScreen> createState() => _SetupState();
}

class _SetupState extends ConsumerState<SetupScreen> {
  String? selected;
  @override
  void initState() {
    super.initState();
    selected = widget.vehicleId;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    if (selected != null &&
        !s.registeredVehicles.any((v) => v.id == selected)) {
      selected = null;
    }
    selected ??= s.registeredVehicles.firstOrNull?.id;
    final v = s.vehicles.where((v) => v.id == selected).firstOrNull;
    final docs = v == null
        ? 0
        : s.supportLibrary.evidence.where((e) => e.model == v.model).length;
    final rules = v == null
        ? 0
        : s.supportLibrary.rules.where((r) => r.vehicleId == v.id).length;
    return ListView(
      children: [
        const PageTitle('실사용 준비', '차량 등록 → 근거 준비 → 정비 주기 확인 → 점검·정비 기록'),
        Panel(
          title: '준비 상태',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in [
                    ('차량 등록', v != null),
                    ('정비 근거', docs > 0),
                    ('정비 주기', rules > 0),
                  ])
                    Chip(
                      avatar: Icon(
                        item.$2
                            ? Icons.check_circle_outline
                            : Icons.radio_button_unchecked,
                        color: item.$2 ? green : muted,
                        size: 18,
                      ),
                      label: Text('${item.$1} ${item.$2 ? '준비됨' : '미등록'}'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                v == null
                    ? '아래에서 실제 사용할 차량을 먼저 등록해 주세요.'
                    : docs == 0
                    ? '사용 가능한 정비 문서가 있으면 근거를 등록해 주세요. 문서가 없어도 점검과 정비 기록은 사용할 수 있습니다.'
                    : rules == 0
                    ? '확인한 정비 주기를 등록하면 교환 완료 후 잔여 거리가 계산됩니다.'
                    : '기본 자료가 준비되었습니다. 아래의 차량 정비지원 시작으로 진행할 수 있습니다.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '1. 내 차량 등록',
          subtitle: '예제 차량과 구분하여 이 기기에 저장합니다.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s.registeredVehicles.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(selected),
                  initialValue: v?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '준비할 등록 차량'),
                  items: s.registeredVehicles
                      .map(
                        (v) => DropdownMenuItem(
                          value: v.id,
                          child: Text('${v.id} · ${v.model}'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => selected = value),
                ),
              if (s.registeredVehicles.isEmpty)
                note('현재 예제 데이터로 시작한 상태입니다. 실제 사용할 차량을 먼저 등록해 주세요.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final id = await showDialog<String>(
                    context: context,
                    builder: (_) => VehicleRegistrationDialog(store: s),
                  );
                  if (id != null && mounted) setState(() => selected = id);
                },
                child: const Text('차량 등록'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '2. 정비 근거 준비',
          subtitle: v == null ? '차량을 먼저 등록해 주세요.' : '${v.model} · 등록 근거 $docs건',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              note(
                '사용 가능한 지침서의 원문 구간과 문서명·개정판·쪽 또는 절을 등록합니다. 차종이 같은 차량은 근거를 함께 검색합니다.',
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: v == null
                    ? null
                    : () => showEvidenceEditor(context, s, v.model, ''),
                child: const Text('정비 근거 등록'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '3. 정비 주기 확인',
          subtitle: v == null ? '차량을 먼저 등록해 주세요.' : '${v.id} · 등록 주기 $rules건',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              note(
                '확인한 지침의 주기와 마지막 교환일·당시 계기를 등록합니다. 주기를 모르면 기록 관리부터 시작하고 나중에 등록할 수 있습니다.',
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: v == null
                    ? null
                    : () => showRuleEditor(context, s, v.id, ''),
                child: const Text('정비 주기 등록'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '4. 점검·정비 시작',
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                onPressed: v == null
                    ? null
                    : () => context.go(supportUrl(v.id)),
                child: const Text('차량 정비지원 시작'),
              ),
              OutlinedButton(
                onPressed: v == null
                    ? null
                    : () => context.go('/vehicles/${v.id}'),
                child: const Text('차량 상세'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class VehicleRegistrationDialog extends StatefulWidget {
  const VehicleRegistrationDialog({required this.store, super.key});
  final AppStore store;
  @override
  State<VehicleRegistrationDialog> createState() => _VehicleRegistrationState();
}

class _VehicleRegistrationState extends State<VehicleRegistrationDialog> {
  final form = GlobalKey<FormState>();
  final fields = {
    for (final key in [
      '차량번호',
      '차종',
      '출고연도',
      '누적 주행거리(km)',
      '누적 주행시간(H)',
      '누적 유류 사용량(L)',
    ])
      key: TextEditingController(),
  };
  String? error;
  bool saving = false;
  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('차량 등록'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in fields.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      key: ValueKey('register-${e.key}'),
                      controller: e.value,
                      enabled: !saving,
                      keyboardType: e.key == '차량번호' || e.key == '차종'
                          ? TextInputType.text
                          : TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '${e.key} *',
                        errorMaxLines: 3,
                        helperText: e.key == '차량번호'
                            ? '한글·영문·숫자·밑줄·하이픈, 40자 이내'
                            : null,
                      ),
                      validator: (raw) {
                        final value = raw?.trim() ?? '';
                        if (value.isEmpty) return '필수 입력 항목입니다.';
                        if (e.key == '차량번호') {
                          if (!RegExp(r'^[A-Za-z0-9가-힣_-]{1,40}$')
                                  .hasMatch(value) ||
                              value.startsWith('MOCK-')) {
                            return '차량번호 형식을 확인해 주세요. MOCK-는 예제 전용입니다.';
                          }
                          if (widget.store.vehicles.any((v) => v.id == value)) {
                            return '이미 등록된 차량번호입니다.';
                          }
                        } else if (e.key == '차종') {
                          if (value.length > 300) {
                            return '차종은 300자 이내로 입력해 주세요.';
                          }
                        } else {
                          final n = parseKm(value);
                          if (n == null || n < 0 || n > 1000000000000) {
                            return '0 이상의 누적값을 입력해 주세요. 쉼표도 사용할 수 있습니다.';
                          }
                          if (e.key == '출고연도' &&
                              (n < 1950 || n > widget.store.clock().year)) {
                            return '출고연도를 확인해 주세요.';
                          }
                        }
                        return null;
                      },
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
                  if (!form.currentState!.validate()) return;
                  setState(() => saving = true);
                  try {
                    final v = Vehicle(
                      id: fields['차량번호']!.text.trim(),
                      model: fields['차종']!.text.trim(),
                      year: parseKm(fields['출고연도']!.text)!,
                      distance: parseKm(fields['누적 주행거리(km)']!.text)!,
                      hours: parseKm(fields['누적 주행시간(H)']!.text)!,
                      fuel: parseKm(fields['누적 유류 사용량(L)']!.text)!,
                      risk: 0,
                    );
                    await widget.store.registerVehicle(v);
                    if (context.mounted) {
                      setState(() => saving = false);
                      Navigator.pop(context, v.id);
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        saving = false;
                        error = e is ArgumentError
                            ? e.message.toString()
                            : '등록하지 못했습니다. 다시 시도해 주세요.';
                      });
                    }
                  }
                },
          child: Text(saving ? '저장 중…' : '등록'),
        ),
      ],
    ),
  );
}
