import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/store.dart';
import 'components.dart';
import 'support.dart';

Map<String, num> _systemCounts(List<Maintenance> records) {
  final map = <String, num>{};
  for (final r in records) {
    map.update(r.system, (v) => v + 1, ifAbsent: () => 1);
  }
  return map;
}

class VehiclesScreen extends ConsumerStatefulWidget {
  const VehiclesScreen({super.key});
  @override
  ConsumerState<VehiclesScreen> createState() => _VehiclesState();
}

class _VehiclesState extends ConsumerState<VehiclesScreen> {
  final search = TextEditingController();
  String status = '전체', sort = '확률 높은 순', year = '전체';
  int page = 0;
  bool showExamples = false;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    final filtered = s.vehicles
        .where(
          (v) =>
              (showExamples ||
                  s.registeredVehicles.isEmpty ||
                  !v.id.startsWith('MOCK-')) &&
              ('${v.id} ${v.model}'.toLowerCase().contains(
                search.text.toLowerCase(),
              )) &&
              (status == '전체' || statusLabel(v.status) == status) &&
              (year == '전체' || '${v.year}' == year),
        )
        .toList();
    filtered.sort(
      (a, b) => sort == '주행거리 높은 순'
          ? b.distance.compareTo(a.distance)
          : sort == '차량번호 순'
          ? a.id.compareTo(b.id)
          : (b.predictionReady ? b.risk : -1).compareTo(
              a.predictionReady ? a.risk : -1,
            ),
    );
    final start = (page * 8).clamp(0, filtered.length);
    return ListView(
      children: [
        PageTitle(
          '차량 현황',
          '차량 운용 실적과 정비 이력을 조회합니다.',
          scopeVehicles: filtered,
          action: OutlinedButton(
            onPressed: () => context.go('/setup'),
            child: const Text('차량 등록'),
          ),
        ),
        SummaryCards(s.activeVehicles),
        const SizedBox(height: 16),
        if (s.registeredVehicles.isNotEmpty)
          CheckboxListTile(
            value: showExamples,
            title: const Text('예제 차량 함께 보기'),
            onChanged: (value) => setState(() {
              showExamples = value ?? false;
              page = 0;
            }),
          ),
        Panel(
          title: '검색 및 필터',
          padding: 12,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() => page = 0),
                  decoration: const InputDecoration(
                    hintText: '차량번호 또는 차종 검색',
                    prefixIcon: Padding(
                      padding: EdgeInsets.all(14),
                      child: DesignIcon('1:445', 'imgSearch'),
                    ),
                  ),
                ),
              ),
              _dropdown(
                status,
                ['전체', '낮음', '관찰', '높음', '미분석'],
                (v) => setState(() {
                  status = v;
                  page = 0;
                }),
              ),
              _dropdown(
                year,
                ['전체', ...s.vehicles.map((v) => '${v.year}').toSet()],
                (v) => setState(() {
                  year = v;
                  page = 0;
                }),
              ),
              _dropdown(sort, [
                '확률 높은 순',
                '주행거리 높은 순',
                '차량번호 순',
              ], (v) => setState(() => sort = v)),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  search.clear();
                  status = '전체';
                  year = '전체';
                  sort = '확률 높은 순';
                  page = 0;
                }),
                icon: const DesignIcon('1:445', 'imgRotateCcw'),
                label: const Text('필터 초기화'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '전체 차량 목록',
          subtitle: '${filtered.length}대 · 차량을 선택하면 상세 정비 이력으로 이동합니다.',
          child: Column(
            children: [
              if (filtered.isEmpty)
                empty('검색 조건에 맞는 차량이 없습니다.')
              else
                DataGrid(
                  minWidth: 1000,
                  columns: const [
                    '차량 부여번호',
                    '출고연도',
                    '누적 주행거리',
                    '누적 주행시간',
                    '유류 사용량',
                    '정비 횟수',
                    '최근 정비일',
                    '예측 확률',
                    '상태',
                    '상세',
                  ],
                  rows: filtered.skip(start).take(8).map((v) {
                    final h = s.history(v.id);
                    return [
                      TextButton(
                        onPressed: () => context.go('/vehicles/${v.id}'),
                        child: cell(v.id, bold: true),
                      ),
                      cell('${v.year}'),
                      cell('${number(v.distance)}km', bold: true),
                      cell('${number(v.hours)}H'),
                      cell('${number(v.fuel)}L'),
                      cell('${h.length}회'),
                      cell(h.isEmpty ? '—' : h.first.date.replaceAll('-', '.')),
                      SizedBox(
                        width: 90,
                        child: Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: v.predictionReady ? v.risk / 100 : 0,
                                color: statusColor(v.status),
                                backgroundColor: line,
                                minHeight: 5,
                              ),
                            ),
                            const SizedBox(width: 6),
                            cell(
                              v.predictionReady ? '${v.risk}%' : '—',
                              color: statusColor(v.status),
                            ),
                          ],
                        ),
                      ),
                      StatusBadge(v.status),
                      IconButton(
                        onPressed: () => context.go('/vehicles/${v.id}'),
                        icon: const DesignIcon('1:445', 'imgChevronRight'),
                      ),
                    ];
                  }).toList(),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: cell(
                      '전체 ${filtered.length}대 중 ${filtered.isEmpty ? 0 : start + 1}–${(start + 8).clamp(0, filtered.length)}대 표시',
                      color: muted,
                    ),
                  ),
                  IconButton(
                    onPressed: page > 0 ? () => setState(() => page--) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${page + 1}'),
                  IconButton(
                    onPressed: start + 8 < filtered.length
                        ? () => setState(() => page++)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _dropdown(
  String value,
  List<String> items,
  ValueChanged<String> change,
) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 12),
  decoration: BoxDecoration(
    border: Border.all(color: line),
    borderRadius: BorderRadius.circular(6),
  ),
  child: DropdownButton<String>(
    value: value,
    underline: const SizedBox(),
    items: items
        .map(
          (s) => DropdownMenuItem(
            value: s,
            child: Text(s, style: const TextStyle(fontSize: 12)),
          ),
        )
        .toList(),
    onChanged: (v) {
      if (v != null) change(v);
    },
  ),
);

class VehicleDetailScreen extends ConsumerWidget {
  const VehicleDetailScreen({required this.id, super.key});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(storeProvider);
    if (!s.vehicles.any((v) => v.id == id)) return empty('차량을 찾을 수 없습니다.');
    final v = s.vehicle(id), h = s.history(id);
    return ListView(
      children: [
        PageTitle(
          '차량번호 $id',
          '${v.model} · 운용·정비 상세 현황',
          scopeVehicles: [v],
          action: OutlinedButton(
            onPressed: () => context.go('/vehicles'),
            child: const Text('목록으로'),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            StatusBadge(v.status),
            cell(
              v.predictionReady
                  ? '로컬 목업 예측 ${v.risk}% · 실제 고장 판정 아님'
                  : '${s.predictionUnavailableReason(v.id)} · 분석 보류',
              color: muted,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Panel(
          title: '운용 정보',
          subtitle: '차량 누적 계기 및 불출 기록',
          child: LayoutBuilder(
            builder: (context, c) => Wrap(
              spacing: 12,
              runSpacing: 16,
              children: [
                for (final pair in [
                  ('출고연도', '${v.year}년'),
                  ('누적 주행거리', '${number(v.distance)} km'),
                  ('누적 주행시간', '${number(v.hours)} H'),
                  ('유류 사용량', '${number(v.fuel)} L'),
                ])
                  SizedBox(
                    width: c.maxWidth < 600
                        ? (c.maxWidth - 12) / 2
                        : (c.maxWidth - 36) / 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cell(pair.$1, color: muted),
                        const SizedBox(height: 8),
                        Text(
                          pair.$2,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ResponsiveColumns(
          children: [
            Panel(
              title: '다음 달 고장수리 예측',
              subtitle: '기기 내 추론 · 목업으로 학습한 모델',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.predictionReady ? '${v.risk}%' : '—',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.w800,
                      color: statusColor(v.status),
                    ),
                  ),
                  LinearProgressIndicator(
                    value: v.predictionReady ? v.risk / 100 : 0,
                    color: statusColor(v.status),
                    backgroundColor: line,
                    minHeight: 9,
                  ),
                  const SizedBox(height: 16),
                  note(
                    '목업 학습 모델의 추정치입니다. 저장 시 다시 계산되며, 진행 중인 월은 임시 추정입니다. 실제 고장이나 안전 상태를 판정하지 않습니다.',
                    color: Colors.orange,
                  ),
                ],
              ),
            ),
            Panel(
              title: '정비 요약',
              subtitle: '누적 ${h.length}건',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${number(h.fold<int>(0, (sum, r) => sum + r.cost))}원',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  cell('누적 정비 비용 · 최근 정비 ${h.isEmpty ? '없음' : h.first.date}'),
                  const SizedBox(height: 16),
                  Bars(_systemCounts(h)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Panel(
          title: '연결 액션',
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: () => context.go('/records?vehicle=$id'),
                icon: const DesignIcon('1:781', 'imgWrench'),
                label: const Text('정비 이력 보기'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.go('/ai-history?vehicle=$id'),
                icon: const DesignIcon('1:781', 'imgActivity'),
                label: const Text('AI 분석 이력'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.go('/vision?vehicle=$id'),
                icon: const DesignIcon('1:781', 'imgScanLine'),
                label: const Text('비전 점검'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.go(supportUrl(id)),
                icon: const DesignIcon('1:781', 'imgMessageCircle'),
                label: const Text('AI 정비지원'),
              ),
              OutlinedButton(
                onPressed: () => context.go('/plans?vehicle=$id'),
                child: const Text('연간 정비계획'),
              ),
              FilledButton(
                onPressed: () => context.go('/entry?vehicle=$id'),
                child: const Text('정비 등록'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(title: '정비 이력', child: _recordTable(context, h)),
      ],
    );
  }
}

Widget _recordTable(BuildContext context, List<Maintenance> records) =>
    records.isEmpty
    ? empty('등록된 정비 기록이 없습니다.')
    : DataGrid(
        minWidth: 850,
        columns: const ['정비일자', '차량번호', '계통', '수리부속 품명', '정비 내용', '가격', '상세'],
        rows: records
            .map(
              (r) => [
                cell(r.date.replaceAll('-', '.')),
                cell(r.vehicleId, bold: true),
                cell(r.system),
                cell(r.part),
                SizedBox(
                  width: 230,
                  child: Text(
                    r.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                cell('${number(r.cost)}원'),
                IconButton(
                  onPressed: () => context.go('/records/${r.id}'),
                  icon: const DesignIcon('1:1346', 'imgChevronRight'),
                ),
              ],
            )
            .toList(),
      );

class RecordsScreen extends ConsumerStatefulWidget {
  const RecordsScreen({super.key});
  @override
  ConsumerState<RecordsScreen> createState() => _RecordsState();
}

class _RecordsState extends ConsumerState<RecordsScreen> {
  final search = TextEditingController();
  String vehicle = '전체', system = '전체';
  bool newest = true;
  bool initialized = false;
  int page = 0;
  static const pageSize = 12;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    if (!initialized) {
      final value = GoRouterState.of(context).uri.queryParameters['vehicle'];
      if (s.vehicles.any((v) => v.id == value)) vehicle = value!;
      initialized = true;
    }
    final rows = s.records
        .where(
          (r) =>
              (vehicle == '전체'
                  ? s.activeVehicles.any((v) => v.id == r.vehicleId)
                  : r.vehicleId == vehicle) &&
              (system == '전체' || r.system == system) &&
              '${r.vehicleId} ${r.part} ${r.description}'.contains(search.text),
        )
        .toList();
    if (!newest) rows.sort((a, b) => b.cost.compareTo(a.cost));
    final currentPage = page.clamp(
      0,
      rows.isEmpty ? 0 : (rows.length - 1) ~/ pageSize,
    );
    final start = currentPage * pageSize;
    return ListView(
      children: [
        PageTitle(
          '정비 기록',
          '차량별 정비 이력을 검색하고 상세 내용을 확인합니다.',
          scopeVehicles: vehicle == '전체'
              ? s.activeVehicles
              : [s.vehicle(vehicle)],
          action: FilledButton(
            onPressed: () => context.go('/entry'),
            child: const Text('정비 등록'),
          ),
        ),
        Panel(
          title: '검색 및 필터',
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 300,
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() => page = 0),
                  decoration: const InputDecoration(
                    hintText: '차량번호, 부품명, 정비 내용 검색',
                    prefixIcon: Padding(
                      padding: EdgeInsets.all(14),
                      child: DesignIcon('1:1346', 'imgSearch'),
                    ),
                  ),
                ),
              ),
              _dropdown(
                vehicle,
                ['전체', ...s.vehicles.map((v) => v.id)],
                (v) => setState(() {
                  vehicle = v;
                  page = 0;
                }),
              ),
              _dropdown(
                system,
                ['전체', ...s.records.map((r) => r.system).toSet()],
                (v) => setState(() {
                  system = v;
                  page = 0;
                }),
              ),
              _dropdown(
                newest ? '최신 정비일 순' : '가격 높은 순',
                ['최신 정비일 순', '가격 높은 순'],
                (v) => setState(() {
                  newest = v == '최신 정비일 순';
                  page = 0;
                }),
              ),
              OutlinedButton(
                onPressed: () => setState(() {
                  search.clear();
                  vehicle = '전체';
                  system = '전체';
                  newest = true;
                  page = 0;
                }),
                child: const Text('필터 초기화'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '전체 정비 기록',
          subtitle: '${rows.length}건 · 등록된 비용 기준',
          child: Column(
            children: [
              _recordTable(context, rows.skip(start).take(pageSize).toList()),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: cell(
                      '${rows.length}건 중 ${rows.isEmpty ? 0 : start + 1}–${(start + pageSize).clamp(0, rows.length)}건',
                      color: muted,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('previous-record-page'),
                    onPressed: currentPage > 0
                        ? () => setState(() => page = currentPage - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${currentPage + 1}'),
                  IconButton(
                    key: const ValueKey('next-record-page'),
                    onPressed: start + pageSize < rows.length
                        ? () => setState(() => page = currentPage + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class RecordDetailScreen extends ConsumerWidget {
  const RecordDetailScreen({required this.id, super.key});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(storeProvider);
    final matches = s.records.where((r) => r.id == id);
    if (matches.isEmpty) return empty('정비 기록을 찾을 수 없습니다.');
    final r = matches.first;
    return ListView(
      children: [
        PageTitle(
          '정비 기록 상세',
          '기록 ID · ${r.id}',
          scopeVehicles: [s.vehicle(r.vehicleId)],
          action: OutlinedButton(
            onPressed: () => context.go('/records?vehicle=${r.vehicleId}'),
            child: const Text('뒤로가기'),
          ),
        ),
        Panel(
          title: '기본 정보',
          child: Wrap(
            spacing: 48,
            runSpacing: 20,
            children: [
              for (final pair in [
                ('차량번호', r.vehicleId),
                ('정비일자', r.date),
                ('차종', s.vehicle(r.vehicleId).model),
                ('정비 계통', r.system),
                ('가격', '${number(r.cost)}원'),
                if (r.odometerKm != null)
                  ('교환 당시 계기', '${number(r.odometerKm!)} km'),
                ('교환 여부', replacementStatusLabel(r.replacementCompleted)),
              ])
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    cell(pair.$1, color: muted),
                    const SizedBox(height: 10),
                    Text(
                      pair.$2,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ResponsiveColumns(
          flexes: const [2, 1],
          children: [
            Panel(
              title: '정비 내용 상세',
              subtitle: '기기 내 등록 기록',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  cell('수리부속 품명', color: muted),
                  const SizedBox(height: 8),
                  Text(
                    r.part,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Divider(height: 36),
                  cell('정비 내용', color: muted),
                  const SizedBox(height: 10),
                  Text(r.description, style: const TextStyle(height: 1.8)),
                  const SizedBox(height: 32),
                  note('인증 없이 사용하는 현장 모드입니다. 이 기록은 사용자 승인·신원 인증을 의미하지 않습니다.'),
                ],
              ),
            ),
            Panel(
              title: '관련 정보',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('edit-maintenance'),
                    onPressed: () => context.go('/entry?record=${r.id}'),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('정비 기록 수정'),
                  ),
                  if (r.inspectionId != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => context.go(
                        '/vision?vehicle=${r.vehicleId}&session=${r.inspectionId}',
                      ),
                      child: const Text('연결된 점검·사진 보기'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () =>
                        context.go('/plans?vehicle=${r.vehicleId}'),
                    child: const Text('다음 정비계획 보기'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('delete-maintenance'),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('정비 기록 삭제'),
                          content: Text(
                            '${r.date} · ${r.part}\n이 기록을 삭제하고 집계와 예측을 갱신합니다. 변경 이력은 보관합니다.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('취소'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('삭제'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true || !context.mounted) return;
                      try {
                        await s.deleteMaintenance(r.id);
                        if (context.mounted) {
                          context.go('/records?vehicle=${r.vehicleId}');
                        }
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('삭제하지 못했습니다. 다시 시도해 주세요.'),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('정비 기록 삭제'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => context.go('/vehicles/${r.vehicleId}'),
                    child: const Text('관련 차량 상세 보기'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () =>
                        context.go('/ai-history?vehicle=${r.vehicleId}'),
                    child: const Text('관련 AI 분석 이력'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () =>
                        context.go('/vision?vehicle=${r.vehicleId}'),
                    child: const Text('비전 점검 열기'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({super.key});
  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisState();
}

class _AnalysisState extends ConsumerState<AnalysisScreen> {
  DateTime from = DateTime(2026, 1, 1), to = DateTime.now();
  Future<void> pick(bool start) async {
    final value = await showDatePicker(
      context: context,
      initialDate: start ? from : to,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (value != null) {
      setState(() {
        if (start) {
          from = value;
        } else {
          to = value;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    final rows = s.records.where((r) {
      final d = DateTime.parse(r.date);
      return s.activeVehicles.any((v) => v.id == r.vehicleId) &&
          !d.isBefore(from) &&
          !d.isAfter(to);
    }).toList();
    final cost = rows.fold<int>(0, (sum, r) => sum + r.cost);
    final months = <String, num>{};
    for (final r in rows) {
      months.update(r.date.substring(0, 7), (v) => v + 1, ifAbsent: () => 1);
    }
    final ranked = [...s.activeVehicles]
      ..sort(
        (a, b) => rows
            .where((r) => r.vehicleId == b.id)
            .fold<int>(0, (n, r) => n + r.cost)
            .compareTo(
              rows
                  .where((r) => r.vehicleId == a.id)
                  .fold<int>(0, (n, r) => n + r.cost),
            ),
      );
    return ListView(
      children: [
        PageTitle(
          '정비 분석',
          '조회 대상 차량의 정비 발생 현황과 비용을 분석합니다.',
          scopeVehicles: s.activeVehicles,
        ),
        Panel(
          title: '분석 기간',
          child: Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () => pick(true),
                icon: const DesignIcon('1:1030', 'imgCalendarDays'),
                label: Text('시작일 ${day(from)}'),
              ),
              const Text('–'),
              OutlinedButton.icon(
                onPressed: () => pick(false),
                icon: const DesignIcon('1:1030', 'imgCalendarDays1'),
                label: Text('종료일 ${day(to)}'),
              ),
              if (from.isAfter(to))
                const Text(
                  '시작일은 종료일보다 늦을 수 없습니다.',
                  style: TextStyle(color: Colors.red),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '정비 지표',
          child: Wrap(
            spacing: 36,
            runSpacing: 18,
            children: [
              for (final pair in [
                ('총 정비 건수', '${rows.length}건'),
                ('정비 차량 수', '${rows.map((r) => r.vehicleId).toSet().length}대'),
                ('누적 정비 비용', '${number(cost)}원'),
                (
                  '평균 정비 비용',
                  '${number(rows.isEmpty ? 0 : cost ~/ rows.length)}원',
                ),
              ])
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    cell(pair.$1, color: muted),
                    const SizedBox(height: 8),
                    Text(
                      pair.$2,
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ResponsiveColumns(
          children: [
            Panel(
              title: '계통별 정비 발생 현황',
              child: rows.isEmpty
                  ? empty('해당 기간의 기록이 없습니다.')
                  : Bars(_systemCounts(rows)),
            ),
            Panel(
              title: '월별 정비 건수 추이',
              child: Bars(
                Map.fromEntries(
                  months.entries.toList()
                    ..sort((a, b) => a.key.compareTo(b.key)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Panel(
          title: '정비 비용 상위 차량',
          action: TextButton(
            onPressed: () => context.go('/records'),
            child: const Text('전체 정비 기록 보기 →'),
          ),
          child: DataGrid(
            columns: const ['순위', '차량번호', '정비횟수', '누적 정비비용'],
            rows: ranked.take(5).toList().asMap().entries.map((e) {
              final h = rows.where((r) => r.vehicleId == e.value.id);
              return [
                cell('${e.key + 1}'),
                TextButton(
                  onPressed: () => context.go('/vehicles/${e.value.id}'),
                  child: cell(e.value.id, bold: true),
                ),
                cell('${h.length}회'),
                cell(
                  '${number(h.fold<int>(0, (n, r) => n + r.cost))}원',
                  bold: true,
                ),
              ];
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class AiHistoryScreen extends ConsumerStatefulWidget {
  const AiHistoryScreen({this.vehicleId, super.key});
  final String? vehicleId;
  @override
  ConsumerState<AiHistoryScreen> createState() => _AiHistoryState();
}

class _AiHistoryState extends ConsumerState<AiHistoryScreen> {
  String? selected;
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    selected ??= s.vehicles.any((v) => v.id == widget.vehicleId)
        ? widget.vehicleId
        : s.vehicles.first.id;
    final v = s.vehicle(selected!);
    final sessions = s.inspections
        .where((i) => i.vehicleId == selected)
        .toList();
    return ListView(
      children: [
        PageTitle(
          'AI 분석 이력',
          '차량별 분석 결과와 비전 점검 기록을 확인합니다.',
          scopeVehicles: [v],
        ),
        note(
          '규칙 기반 잔여 정비거리 + 정비기록 분류를 사용합니다. 아래 고장 확률은 합성 예제이며 실제 차량의 예측값이 아닙니다.',
          color: Colors.orange,
        ),
        const SizedBox(height: 16),
        Panel(
          title: '선택 차량',
          child: Wrap(
            spacing: 28,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dropdown(
                selected!,
                s.vehicles.map((v) => v.id).toList(),
                (value) => setState(() => selected = value),
              ),
              StatusBadge(v.status),
              cell(
                v.predictionReady ? '목업 예측 ${v.risk}%' : '예측 없음',
                bold: true,
              ),
              FilledButton(
                onPressed: () => context.go('/vision?vehicle=$selected'),
                child: const Text('비전 점검 시작'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '로컬 예측 이력',
          subtitle: '다음 달 고장수리 추정 · 진행 중인 월은 임시 결과',
          child:
              s.predictionHistory
                  .where((r) => r['vehicleId'] == selected)
                  .isEmpty
              ? empty('예측에 필요한 월별 운용 기록이 없습니다.')
              : DataGrid(
                  columns: const ['계산일시', '갱신 사유', '추정 확률', '상태'],
                  rows: s.predictionHistory
                      .where((r) => r['vehicleId'] == selected)
                      .take(20)
                      .map(
                        (r) => [
                          cell(
                            (r['created'] as String)
                                .substring(0, 16)
                                .replaceAll('T', ' '),
                          ),
                          cell(r['trigger'] as String),
                          cell(
                            '${((r['probability'] as num) * 100).toStringAsFixed(1)}%',
                          ),
                          cell(
                            r['provisional'] == true ? '부분월 임시 추정' : '월말 관측',
                          ),
                        ],
                      )
                      .toList(),
                ),
        ),
        const SizedBox(height: 16),
        Panel(
          title: '저장된 비전 점검 세션',
          subtitle: '${sessions.length}건 · 수동 점검 기록',
          child: sessions.isEmpty
              ? empty('저장된 촬영 기록이 없습니다.')
              : DataGrid(
                  columns: const ['점검일시', '부위', '모드', '기록'],
                  rows: sessions
                      .map(
                        (i) => [
                          cell(i.created.substring(0, 16).replaceAll('T', ' ')),
                          cell(i.area),
                          cell(i.mode),
                          SizedBox(
                            width: 260,
                            child: cell(
                              i.note.isEmpty ? '수동 촬영 · AI 미판정' : i.note,
                            ),
                          ),
                        ],
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }
}
