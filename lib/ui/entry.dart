import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/store.dart';
import '../data/clock.dart';
import 'components.dart';
import 'support.dart';
import 'system_pilot_panel.dart';
import '../data/adaptive_runtime.dart';

class EntryScreen extends ConsumerStatefulWidget {
  const EntryScreen({
    this.vehicleId,
    this.initialMaintenance = true,
    this.recordId,
    this.inspectionId,
    this.initialPart,
    super.key,
  });
  final String? vehicleId;
  final String? recordId;
  final String? inspectionId, initialPart;
  final bool initialMaintenance;
  @override
  ConsumerState<EntryScreen> createState() => _EntryState();
}

class _EntryState extends ConsumerState<EntryScreen> {
  final form = GlobalKey<FormState>();
  final part = TextEditingController(),
      cost = TextEditingController(),
      description = TextEditingController(),
      year = TextEditingController(),
      distance = TextEditingController(),
      hours = TextEditingController(),
      fuel = TextEditingController();
  final odometer = TextEditingController();
  String? inspectionId, savedRecordId;
  String? conceptSelection, confirmedConceptId;
  bool conceptTouched = false;
  bool? replacementCompleted;
  String? vehicle;
  String system = '냉각';
  String maintenanceType = '미분류';
  DateTime date = DateTime.now();
  late bool maintenance;
  bool saving = false;
  String? success;
  @override
  void initState() {
    super.initState();
    maintenance = widget.initialMaintenance;
    date = ref.read(currentTimeProvider);
    if (widget.recordId != null) {
      final s = ref.read(storeProvider);
      final r = s.records.firstWhere((r) => r.id == widget.recordId);
      loadVehicle(s, r.vehicleId);
      part.text = r.part;
      cost.text = '${r.cost}';
      description.text = r.description;
      system = r.system;
      maintenanceType = r.maintenanceType;
      date = DateTime.parse(r.date);
      maintenance = true;
      inspectionId = r.inspectionId;
      replacementCompleted = r.replacementCompleted;
      odometer.text = r.odometerKm?.toString() ?? '';
      conceptSelection = r.confirmedConceptId;
      confirmedConceptId = r.confirmedConceptId;
    } else {
      part.text = standardPart(widget.initialPart ?? '');
      final s = ref.read(storeProvider);
      final inspection = s.inspections
          .where((i) => i.id == widget.inspectionId)
          .firstOrNull;
      if (inspection != null) {
        inspectionId = inspection.id;
        loadVehicle(s, inspection.vehicleId);
        part.text = standardPart(inspection.area);
        description.text = inspection.note;
        // Prior photo confirmation only preselects a candidate; this record still
        // requires its own explicit confirmation checkbox.
        conceptSelection = inspection.confirmedConceptId;
        maintenance = true;
      }
    }
    var previousPart = part.text;
    part.addListener(() {
      if (!mounted) return;
      if (part.text == previousPart) return;
      previousPart = part.text;
      setState(() {
        conceptSelection = null;
        confirmedConceptId = null;
        conceptTouched = true;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [part, cost, description, year, distance, hours, fuel]) {
      c.dispose();
    }
    odometer.dispose();
    super.dispose();
  }

  void loadVehicle(AppStore s, String id) {
    vehicle = id;
    final v = s.vehicle(id);
    year.text = '${v.year}';
    distance.text = '${v.distance}';
    hours.text = '${v.hours}';
    fuel.text = '${v.fuel}';
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      saving = true;
      success = null;
    });
    try {
      final s = ref.read(storeProvider);
      if (maintenance) {
        final record = Maintenance(
          id: widget.recordId ?? s.newId('MR'),
          vehicleId: vehicle!,
          date: date.toIso8601String().substring(0, 10),
          part: part.text.trim(),
          system: system,
          description: description.text.trim(),
          cost: parseKm(cost.text)!,
          maintenanceType: maintenanceType,
          inspectionId: inspectionId,
          odometerKm: replacementCompleted == true
              ? parseKm(odometer.text)!
              : null,
          replacementCompleted: replacementCompleted,
        );
        if (widget.recordId == null) {
          await s.addMaintenance(
            record,
            confirmedConceptId: confirmedConceptId,
          );
        } else {
          await s.editMaintenance(
            record,
            confirmedConceptId: confirmedConceptId,
            clearConcept: conceptTouched && confirmedConceptId == null,
          );
        }
        savedRecordId = record.id;
      } else {
        await s.updateOperation(
          vehicle!,
          parseKm(year.text)!,
          parseKm(distance.text)!,
          parseKm(hours.text)!,
          parseKm(fuel.text)!,
        );
      }
      if (mounted) {
        setState(
          () => success = widget.recordId == null
              ? '정상적으로 등록되었습니다. 차량 상세와 집계에 반영되었습니다.'
              : '수정되었습니다. 집계와 예측에 반영되었습니다.',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is ArgumentError
                  ? '${e.message}'
                  : '저장하지 못했습니다. 입력값과 저장 공간을 확인하고 다시 시도해 주세요.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget field(
    String label,
    TextEditingController controller, {
    bool numeric = false,
    int lines = 1,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label *',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey(label),
          controller: controller,
          onChanged: (_) {
            if (controller == part || controller == description) {
              setState(() {});
            }
          },
          maxLines: lines,
          keyboardType: numeric
              ? TextInputType.number
              : lines > 1
              ? TextInputType.multiline
              : TextInputType.text,
          validator:
              validator ??
              (v) => (v == null || v.trim().isEmpty) ? '필수 입력 항목입니다.' : null,
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    if (vehicle == null) {
      loadVehicle(
        s,
        s.vehicles.any((v) => v.id == widget.vehicleId)
            ? widget.vehicleId!
            : s.activeVehicles.first.id,
      );
    }
    final old = s.vehicle(vehicle!);
    final suggestion = s.suggestMaintenance(part.text, description.text);
    final candidate = s.supportLibrary.knowledge.concepts
        .where(
          (c) => c['id'] == s.supportLibrary.knowledge.conceptFor(part.text),
        )
        .firstOrNull;
    final recent = [
      ...s.records.map(
        (r) => <String, String>{
          'vehicle': r.vehicleId,
          'type': '정비실적',
          'date': r.date,
          'detail': r.part,
        },
      ),
      ...s.operations.map(
        (o) => <String, String>{
          'vehicle': o['vehicleId'],
          'type': '운용실적',
          'date': o['created'],
          'detail': '${number(o['distance'])}km',
        },
      ),
    ]..sort((a, b) => b['date']!.compareTo(a['date']!));
    return ListView(
      children: [
        PageTitle(
          savedRecordId != null && success != null
              ? '정비 완료'
              : widget.recordId != null
              ? '정비 기록 수정'
              : maintenance
              ? '정비 결과 기록'
              : '운용실적 기록',
          savedRecordId != null && success != null
              ? '저장한 결과를 확인하고 다음 정비계획으로 이어갑니다.'
              : '필수 항목을 입력하고 실제 작업 결과를 저장해 주세요.',
          scopeVehicles: [old],
        ),
        if (savedRecordId != null && success != null) ...[
          Panel(
            title: '정비 기록 저장 완료',
            subtitle: '차량 $vehicle · ${part.text}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                note(success!),
                const SizedBox(height: 12),
                Builder(
                  builder: (context) {
                    final rule = s.supportLibrary.rules
                        .where(
                          (r) =>
                              r.vehicleId == vehicle &&
                              standardPart(r.part) == standardPart(part.text),
                        )
                        .firstOrNull;
                    final result = rule == null
                        ? null
                        : s.serviceDistance(rule);
                    return note(
                      replacementCompleted == true
                          ? rule == null
                                ? '교환 완료와 당시 계기를 저장했습니다. 확인한 정비 주기를 등록하면 다음 정비거리가 계산됩니다.'
                                : result?.remainingKm == null
                                ? (result?.reason ?? '기록을 확인해 주세요.')
                                : '교환 완료를 반영했습니다. 다음 정비까지 ${number(result!.remainingKm!)} km 남았습니다.'
                          : replacementCompleted == null
                          ? '교환 여부 미확인으로 저장했습니다. 교환 여부와 당시 계기를 확인하면 계획을 갱신할 수 있습니다.'
                          : '점검·수리 기록을 저장했습니다. 교환 기준은 유지됩니다.',
                    );
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: () => context.go('/plans?vehicle=$vehicle'),
                      child: const Text('다음 정비계획 확인'),
                    ),
                    OutlinedButton(
                      onPressed: () => context.go('/records/$savedRecordId'),
                      child: const Text('저장한 기록 보기'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          context.go(supportUrl(vehicle!, part.text)),
                      child: const Text('정비 주기 확인·등록'),
                    ),
                    OutlinedButton(
                      onPressed: () => context.go('/entry?vehicle=$vehicle'),
                      child: const Text('새 정비 기록 입력'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (savedRecordId == null || success == null) ...[
          if (widget.recordId == null && inspectionId == null)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: line),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final value in [false, true])
                    TextButton(
                      onPressed: saving
                          ? null
                          : () => setState(() {
                              maintenance = value;
                              success = null;
                              form.currentState?.reset();
                            }),
                      style: TextButton.styleFrom(
                        foregroundColor: maintenance == value ? green : muted,
                        backgroundColor: maintenance == value
                            ? green.withValues(alpha: .07)
                            : null,
                      ),
                      child: Text(value ? '정비실적 등록' : '운용실적 등록'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          ResponsiveColumns(
            breakpoint: 880,
            children: [
              Panel(
                title: maintenance ? '정비실적 등록' : '운용실적 등록',
                subtitle: maintenance ? '완료된 정비 내역 입력' : '차량 누적 운용값 입력',
                child: Form(
                  key: form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '차량 부여번호 *',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: vehicle,
                        items: s.vehicles
                            .map(
                              (v) => DropdownMenuItem(
                                value: v.id,
                                child: Text('${v.id} · ${v.model}'),
                              ),
                            )
                            .toList(),
                        onChanged:
                            saving ||
                                widget.recordId != null ||
                                inspectionId != null
                            ? null
                            : (v) => setState(() {
                                if (v != null) loadVehicle(s, v);
                                success = null;
                              }),
                      ),
                      const SizedBox(height: 16),
                      if (maintenance) ...[
                        if (inspectionId != null) ...[
                          Builder(
                            builder: (context) {
                              final i = s.inspections
                                  .where((i) => i.id == inspectionId)
                                  .firstOrNull;
                              return i == null
                                  ? note('연결된 점검을 찾을 수 없습니다.')
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        note(
                                          '점검 기록 연결 · ${i.area} · ${i.created.substring(0, 10)}\n부품과 메모를 이어받았습니다. 실제 조치 결과를 보완해 주세요.',
                                        ),
                                        const SizedBox(height: 8),
                                        SizedBox(
                                          height: 130,
                                          child: Image.file(
                                            File(i.imagePath),
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, e, stack) =>
                                                const Center(
                                                  child: Text(
                                                    '점검 사진 파일을 찾을 수 없습니다.',
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ],
                                    );
                            },
                          ),
                          const SizedBox(height: 16),
                        ],
                        const Text(
                          '정비일자 *',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () async {
                            final d = await showDatePicker(
                              context: context,
                              initialDate: date,
                              firstDate: DateTime(2000),
                              lastDate: ref.read(currentTimeProvider),
                            );
                            if (d != null) setState(() => date = d);
                          },
                          icon: const DesignIcon('1:1829', 'imgCalendarDays'),
                          label: Text(day(date)),
                        ),
                        const SizedBox(height: 16),
                        field('수리부속 품명', part),
                        if (s.supportLibrary.knowledge.concepts.isNotEmpty) ...[
                          Text(
                            '자동 확정하지 않습니다. 후보: ${candidate?['name'] ?? '정확히 일치하는 후보 없음'}',
                          ),
                          DropdownButtonFormField<String>(
                            key: ValueKey(
                              'concept-selection-${part.text}-$conceptSelection',
                            ),
                            initialValue: conceptSelection ?? 'unconfirmed',
                            decoration: const InputDecoration(
                              labelText: '부품 개념 선택',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: 'unconfirmed',
                                child: Text('미확인'),
                              ),
                              for (final c
                                  in s.supportLibrary.knowledge.concepts)
                                DropdownMenuItem(
                                  value: c['id'] as String,
                                  child: Text(c['name'] as String),
                                ),
                            ],
                            onChanged: (v) => setState(() {
                              conceptSelection = v == 'unconfirmed' ? null : v;
                              confirmedConceptId = null;
                              conceptTouched = true;
                            }),
                          ),
                          CheckboxListTile(
                            key: const ValueKey('confirm-part-concept'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('선택한 부품 개념과 이 정비 기록의 연결을 확인했습니다'),
                            subtitle: const Text('장착 품번·적용조건의 확정을 뜻하지 않습니다.'),
                            value: confirmedConceptId != null,
                            onChanged: conceptSelection == null
                                ? null
                                : (v) => setState(() {
                                    confirmedConceptId = v == true
                                        ? conceptSelection
                                        : null;
                                    conceptTouched = true;
                                  }),
                          ),
                        ],
                        DropdownButtonFormField<String>(
                          key: const ValueKey('replacement-completed'),
                          initialValue: replacementCompleted == null
                              ? 'unknown'
                              : replacementCompleted!
                              ? 'completed'
                              : 'none',
                          decoration: const InputDecoration(labelText: '교환 여부'),
                          items: const [
                            DropdownMenuItem(
                              value: 'unknown',
                              child: Text('미확인'),
                            ),
                            DropdownMenuItem(
                              value: 'none',
                              child: Text('교환 없음'),
                            ),
                            DropdownMenuItem(
                              value: 'completed',
                              child: Text('교환 완료'),
                            ),
                          ],
                          onChanged: saving || savedRecordId != null
                              ? null
                              : (value) => setState(() {
                                  replacementCompleted = switch (value) {
                                    'completed' => true,
                                    'none' => false,
                                    _ => null,
                                  };
                                }),
                        ),
                        note(
                          replacementCompleted == null
                              ? '교환 여부를 확인하지 못한 기록입니다. 교환 기준을 갱신하지 않으며 잔여거리 계산이 보류될 수 있습니다.'
                              : replacementCompleted!
                              ? '실제 교환 당시 계기를 저장하여 다음 정비거리를 갱신합니다.'
                              : '교환하지 않은 점검·수리입니다. 교환 주기를 초기화하지 않습니다.',
                        ),
                        if (replacementCompleted == true) ...[
                          field(
                            '교환 당시 누적 주행거리(km)',
                            odometer,
                            numeric: true,
                            validator: (text) {
                              final value = parseKm(text ?? '');
                              return value == null ||
                                      value < 0 ||
                                      value > old.distance
                                  ? '현재 누적 ${number(old.distance)} km 이하의 실제 교환 계기를 입력해 주세요.'
                                  : null;
                            },
                          ),
                          note(
                            '현재 등록 계기 ${number(old.distance)} km · 계기가 더 늘었다면 운용실적을 먼저 갱신해 주세요.',
                          ),
                          const SizedBox(height: 12),
                        ],
                        const Text(
                          '정비 계통 *',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          key: ValueKey('system-$system'),
                          initialValue: system,
                          items:
                              [
                                    '냉각',
                                    '제동',
                                    '엔진/연료',
                                    '전장',
                                    '조향/현가',
                                    '흡기/배기',
                                    '동력전달',
                                    '공조',
                                    '차체',
                                  ]
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(v),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => system = v);
                          },
                        ),
                        const SizedBox(height: 16),
                        field(
                          '가격(원)',
                          cost,
                          numeric: true,
                          validator: (v) =>
                              parseKm(v ?? '') == null ? '숫자로 입력해 주세요.' : null,
                        ),
                        field('정비내용', description, lines: 4),
                        if (!old.id.startsWith('MOCK-') &&
                            ref
                                .watch(adaptiveRuntimeProvider)
                                .installedModels
                                .any(
                                  (m) => m.id == 'maintenance-system-pilot-v1',
                                ))
                          SystemPilotPanel(
                            text: description.text,
                            identifiers: s.vehicles.map((v) => v.id).toList(),
                            onApply: (label) => setState(() => system = label),
                          ),
                        DropdownButtonFormField<String>(
                          key: ValueKey('type-$maintenanceType'),
                          initialValue: maintenanceType,
                          decoration: const InputDecoration(labelText: '정비 구분'),
                          items: ['미분류', '예방', '고장수리']
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                          onChanged: saving
                              ? null
                              : (value) =>
                                    setState(() => maintenanceType = value!),
                        ),
                        const SizedBox(height: 12),
                        if (old.id.startsWith('MOCK-') &&
                            (part.text.isNotEmpty ||
                                description.text.isNotEmpty))
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              note(
                                suggestion.system.label == null ||
                                        suggestion.type.label == null
                                    ? '목업 분류 모델: 판단을 보류합니다. 정비 계통과 구분을 직접 선택해 주세요.'
                                    : '목업 분류 제안: ${suggestion.system.label} · ${suggestion.type.label}. 실제 정비 결과는 직접 확인해 주세요.',
                              ),
                              if (suggestion.system.label != null &&
                                  suggestion.type.label != null)
                                TextButton(
                                  onPressed: saving
                                      ? null
                                      : () => setState(() {
                                          system = suggestion.system.label!;
                                          maintenanceType =
                                              suggestion.type.label!;
                                        }),
                                  child: const Text('분류 제안 적용'),
                                ),
                            ],
                          ),
                      ] else ...[
                        field(
                          '출고연도',
                          year,
                          numeric: true,
                          validator: (v) {
                            final n = parseKm(v ?? '');
                            return n == null ||
                                    n < 1950 ||
                                    n > DateTime.now().year
                                ? '1950~${DateTime.now().year}년 사이로 입력해 주세요.'
                                : null;
                          },
                        ),
                        field(
                          '누적 주행거리(km)',
                          distance,
                          numeric: true,
                          validator: (v) => _cumulative(v, old.distance),
                        ),
                        field(
                          '누적 주행시간(H)',
                          hours,
                          numeric: true,
                          validator: (v) => _cumulative(v, old.hours),
                        ),
                        field(
                          '유류 사용량(L)',
                          fuel,
                          numeric: true,
                          validator: (v) => _cumulative(v, old.fuel),
                        ),
                      ],
                      if (success != null) ...[
                        note(success!),
                        const SizedBox(height: 16),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: saving
                                  ? null
                                  : () => setState(() {
                                      form.currentState?.reset();
                                      part.clear();
                                      cost.clear();
                                      description.clear();
                                      date = ref.read(currentTimeProvider);
                                      maintenanceType = '미분류';
                                      loadVehicle(s, vehicle!);
                                      success = null;
                                      savedRecordId = null;
                                      inspectionId = null;
                                      replacementCompleted =
                                          widget.recordId == null
                                          ? null
                                          : s.records
                                                .firstWhere(
                                                  (r) =>
                                                      r.id == widget.recordId,
                                                )
                                                .replacementCompleted;
                                      odometer.clear();
                                    }),
                              child: const Text('입력 초기화'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: saving || savedRecordId != null
                                  ? null
                                  : save,
                              child: saving
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('저장'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      cell('저장 시 차량 기록과 비용·운용 집계에 즉시 반영됩니다.', color: muted),
                    ],
                  ),
                ),
              ),
              Panel(
                title: '최근 등록 내역',
                subtitle: '최근 6건 · 등록일시 최신순',
                child: Column(
                  children: [
                    DataScopeNotice(
                      s.vehicles.where(
                        (v) => recent.take(6).any((r) => r['vehicle'] == v.id),
                      ),
                      label: '최근 내역 대상',
                    ),
                    const SizedBox(height: 12),
                    DataGrid(
                      minWidth: 400,
                      columns: const ['차량번호', '구분', '등록일시', '내용'],
                      rows: recent
                          .take(6)
                          .map(
                            (r) => [
                              cell(r['vehicle']!, bold: true),
                              cell(r['type']!),
                              cell(
                                r['date']!
                                    .substring(0, 10)
                                    .replaceAll('-', '.'),
                              ),
                              cell(r['detail']!),
                            ],
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 18),
                    note('등록한 데이터는 현재 기기에 저장됩니다. 앱 삭제 전 필요한 자료를 별도로 보관해 주세요.'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String? _cumulative(String? value, int previous) {
    final n = parseKm(value ?? '');
    return n == null
        ? '숫자로 입력해 주세요.'
        : n < previous
        ? '이전 등록값(${number(previous)})보다 작을 수 없습니다.'
        : null;
  }
}
