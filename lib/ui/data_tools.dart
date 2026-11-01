import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/store.dart';
import 'components.dart';
import 'knowledge_tools.dart';
import 'runtime_settings.dart';

class NativeBackupFiles {
  static const channel = MethodChannel('maintenance/local_files');
  static Future<bool> save(String path, String name) async =>
      await channel.invokeMethod<bool>('saveBackup', {
        'path': path,
        'name': name,
      }) ??
      false;
  static Future<String?> pick() => channel.invokeMethod<String>('pickBackup');
  static Future<void> release(String path) async {
    try {
      await channel.invokeMethod<bool>('releaseBackup', {'path': path});
    } catch (_) {}
  }
}

class DataToolsScreen extends ConsumerStatefulWidget {
  const DataToolsScreen({super.key});
  @override
  ConsumerState<DataToolsScreen> createState() => _DataToolsState();
}

class _DataToolsState extends ConsumerState<DataToolsScreen> {
  bool busy = false, preview = false;
  String? message, vehicleId;
  int operationPage = 0;

  Future<void> run(Future<String?> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await action();
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is ArgumentError
              ? '${e.message}'
              : e is FormatException
              ? e.message
              : '처리하지 못했습니다. 파일과 저장 공간을 확인해 주세요.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          preview = false;
        });
      }
    }
  }

  Future<void> export() => run(() async {
    final s = ref.read(storeProvider);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${s.newId('BACKUP')}.mbackup');
    try {
      await s.exportBackup(file);
      final name =
          'maintenance-${s.clock().toIso8601String().substring(0, 10)}.mbackup';
      return await NativeBackupFiles.save(file.path, name)
          ? '백업 파일을 저장했습니다. 선택한 위치에서 확인해 주세요.'
          : '백업 저장을 취소했습니다.';
    } finally {
      if (await file.exists()) await file.delete();
    }
  });

  Future<void> restore() => run(() async {
    final path = await NativeBackupFiles.pick();
    if (path == null) return '파일 선택을 취소했습니다.';
    try {
      final snapshot = await BackupSnapshot.read(File(path));
      if (!mounted) return null;
      final count = snapshot.counts;
      setState(() => preview = true);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('백업으로 현재 데이터 교체'),
          content: Text(
            '백업 생성: ${snapshot.created.substring(0, 10)}\n차량 ${count['vehicles']}대 · 정비 ${count['maintenance']}건\n운용 ${count['operations']}건 · 점검 사진 ${snapshot.photos.length}개\n\n현재 기기의 기록을 이 백업으로 교체합니다. 먼저 현재 데이터를 백업하는 것을 권장합니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const ValueKey('confirm-restore'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('교체하여 복원'),
            ),
          ],
        ),
      );
      if (mounted) setState(() => preview = false);
      if (confirmed != true) return '복원을 취소했습니다. 현재 데이터는 유지됩니다.';
      final dir = await getApplicationDocumentsDirectory();
      await ref
          .read(storeProvider)
          .restoreBackup(snapshot, Directory('${dir.path}/inspections'));
      return '기록과 점검 사진을 복원했습니다. 집계와 예측을 갱신했습니다.';
    } finally {
      await NativeBackupFiles.release(path);
    }
  });

  Future<void> editOperation(Map<String, dynamic> row) async {
    final controllers = {
      for (final key in ['distance', 'hours', 'fuel'])
        key: TextEditingController(text: '${row[key]}'),
    };
    final form = GlobalKey<FormState>();
    final values = await showDialog<Map<String, int>>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('운용 기록 수정'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${row['created']}\n앞뒤 기록의 누적값 범위를 유지해야 합니다.'),
                for (final pair in [
                  ('distance', '누적 거리(km)'),
                  ('hours', '누적 시간(H)'),
                  ('fuel', '누적 유류량(L)'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextFormField(
                      key: ValueKey('edit-${pair.$1}'),
                      controller: controllers[pair.$1],
                      decoration: InputDecoration(labelText: pair.$2),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (v) =>
                          int.tryParse(v ?? '') == null ? '숫자로 입력해 주세요.' : null,
                    ),
                  ),
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
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(c, {
                  for (final e in controllers.entries)
                    e.key: int.parse(e.value.text),
                });
              }
            },
            child: const Text('수정 저장'),
          ),
        ],
      ),
    );
    // Dispose after the dialog route finishes its exit animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final controller in controllers.values) {
      controller.dispose();
    }
    if (values == null || !mounted) return;
    await run(() async {
      await ref
          .read(storeProvider)
          .editOperation(
            row['id'] as String,
            values['distance']!,
            values['hours']!,
            values['fuel']!,
          );
      return '운용 기록을 수정했습니다. 집계와 예측을 갱신했습니다.';
    });
  }

  Future<void> deleteOperation(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('운용 기록 삭제'),
        content: Text(
          '${row['created']} · ${number(row['distance'] as num)}km\n삭제 후 남은 최신 기록으로 차량 누적값과 예측을 다시 계산합니다.',
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
    if (confirmed != true || !mounted) return;
    await run(() async {
      await ref.read(storeProvider).deleteOperation(row['id'] as String);
      return '운용 기록을 삭제했습니다. 집계와 예측을 갱신했습니다.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    if (!s.vehicles.any((v) => v.id == vehicleId)) {
      vehicleId = s.vehicles.first.id;
      operationPage = 0;
    }
    final rows = s.operations.where((r) => r['vehicleId'] == vehicleId).toList()
      ..sort((a, b) {
        final c = (b['created'] as String).compareTo(a['created'] as String);
        return c != 0
            ? c
            : (b['_localOrder'] as int).compareTo(a['_localOrder'] as int);
      });
    final pages = (rows.length / 12).ceil().clamp(1, 1000000);
    operationPage = operationPage.clamp(0, pages - 1);
    return ListView(
      children: [
        PageTitle(
          '데이터 관리',
          '기기 안의 기록을 백업·복원하고 운용 기록을 수정합니다.',
          scopeVehicles: s.vehicles,
          scopeLabel: '백업 대상',
        ),
        if (busy && !preview) const LinearProgressIndicator(),
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: note(message!),
          ),
        Panel(
          title: '로컬 백업·복원',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '차량·정비·운용·질문·분석·변경 이력과 점검 사진을 한 파일에 보관합니다. 암호화되지 않은 백업이므로 보관 위치를 직접 선택해 주세요. 기기 또는 USB의 로컬 파일을 사용합니다.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('export-backup'),
                    onPressed: busy ? null : export,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('백업 파일 저장'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('import-backup'),
                    onPressed: busy ? null : restore,
                    icon: const Icon(Icons.restore),
                    label: const Text('백업 파일 복원'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('import-knowledge'),
                    onPressed: busy
                        ? null
                        : () => run(
                            () => importKnowledgeFile(
                              context,
                              ref.read(storeProvider),
                            ),
                          ),
                    icon: const Icon(Icons.library_add),
                    label: const Text('정비 자료 반입'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (s.supportLibrary.knowledge.concepts.isNotEmpty) ...[
          KnowledgePanel(store: s),
          const SizedBox(height: 16),
        ],
        Panel(
          title: '운용 기록 관리',
          subtitle: '전체 기간의 운용 기록 · 정비 수정·삭제는 정비 기록 상세에서 가능합니다.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DataScopeNotice([s.vehicle(vehicleId!)]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('manage-$vehicleId'),
                initialValue: vehicleId,
                items: s.vehicles
                    .map(
                      (v) => DropdownMenuItem(value: v.id, child: Text(v.id)),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        vehicleId = v;
                        operationPage = 0;
                      }),
              ),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                const Text('운용 기록이 없습니다.')
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      for (final label in [
                        '기록 시각',
                        '거리(km)',
                        '시간(H)',
                        '유류(L)',
                        '관리',
                      ])
                        DataColumn(label: Text(label)),
                    ],
                    rows: rows
                        .skip(operationPage * 12)
                        .take(12)
                        .map(
                          (r) => DataRow(
                            cells: [
                              DataCell(Text(r['created'] as String)),
                              DataCell(Text(number(r['distance'] as num))),
                              DataCell(Text(number(r['hours'] as num))),
                              DataCell(Text(number(r['fuel'] as num))),
                              DataCell(
                                Row(
                                  children: [
                                    IconButton(
                                      key: ValueKey('edit-op-${r['id']}'),
                                      tooltip: '수정',
                                      onPressed: busy
                                          ? null
                                          : () => editOperation(r),
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                    IconButton(
                                      key: ValueKey('delete-op-${r['id']}'),
                                      tooltip: '삭제',
                                      onPressed: busy
                                          ? null
                                          : () => deleteOperation(r),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                        .toList(),
                  ),
                ),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('총 ${rows.length}건 · ${operationPage + 1}/$pages 페이지'),
                  TextButton(
                    key: const ValueKey('operations-previous'),
                    onPressed: busy || operationPage == 0
                        ? null
                        : () => setState(() => operationPage--),
                    child: const Text('이전'),
                  ),
                  TextButton(
                    key: const ValueKey('operations-next'),
                    onPressed: busy || operationPage + 1 >= pages
                        ? null
                        : () => setState(() => operationPage++),
                    child: const Text('다음'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ChangeHistory(
          key: ValueKey('changes-$vehicleId'),
          store: s,
          vehicleId: vehicleId!,
        ),
        TextButton.icon(
          key: const ValueKey('open-runtime-settings'),
          icon: const Icon(Icons.memory),
          label: const Text('기기 사양·모델 단계 설정'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (c) => AlertDialog(
              content: const SizedBox(
                width: 600,
                child: SingleChildScrollView(child: RuntimeSettingsPanel()),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('닫기'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ChangeHistory extends StatefulWidget {
  const ChangeHistory({
    super.key,
    required this.store,
    required this.vehicleId,
  });
  final AppStore store;
  final String vehicleId;
  @override
  State<ChangeHistory> createState() => _ChangeHistoryState();
}

class _ChangeHistoryState extends State<ChangeHistory> {
  int page = 0;
  late Future<({int total, List<Map<String, dynamic>> rows})> result;
  @override
  void initState() {
    super.initState();
    result = widget.store.recordChanges(widget.vehicleId);
    widget.store.addListener(reload);
  }

  void reload() {
    if (mounted) {
      setState(() {
        page = 0;
        result = widget.store.recordChanges(widget.vehicleId);
      });
    }
  }

  void move(int next) => setState(() {
    page = next;
    result = widget.store.recordChanges(widget.vehicleId, page: page);
  });
  @override
  void dispose() {
    widget.store.removeListener(reload);
    super.dispose();
  }

  Future<void> detail(Map<String, dynamic> row) => showDialog<void>(
    context: context,
    builder: (c) {
      final before = row['before'] as Map;
      final after = row['after'] as Map?;
      const labels = {
        'date': '정비 날짜',
        'created': '기록 시각',
        'part': '부속',
        'description': '정비 내용',
        'system': '계통',
        'maintenanceType': '정비 유형',
        'cost': '비용(원)',
        'distance': '거리(km)',
        'hours': '시간(H)',
        'fuel': '유류(L)',
      };
      return AlertDialog(
        title: Text(after == null ? '삭제 전 기록' : '변경 전후 비교'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('기록: ${row['recordId']}\n변경 시각: ${row['created']}'),
                for (final e in labels.entries)
                  if (before.containsKey(e.key) &&
                      (after == null || before[e.key] != after[e.key]))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        '${e.value}\n${before[e.key]} → ${after == null ? '삭제됨' : after[e.key]}',
                      ),
                    ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('닫기'),
          ),
        ],
      );
    },
  );
  @override
  Widget build(BuildContext context) => Panel(
    title: '수정·삭제 이력',
    subtitle: '선택 차량의 기록 변경 내역 · 서버 전송 없이 기기에 보관합니다.',
    child: FutureBuilder(
      future: result,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return TextButton(
            onPressed: reload,
            child: const Text('이력을 불러오지 못했습니다. 다시 시도'),
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return const Text('변경 이력을 불러오는 중입니다.');
        }
        final data = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data.rows.isEmpty) const Text('수정·삭제 이력이 없습니다.'),
            for (final row in data.rows)
              Material(
                color: Colors.transparent,
                child: ListTile(
                  key: ValueKey('change-${row['id']}'),
                  title: Text(
                    '${row['table'] == 'operations' ? '운용' : '정비'} ${row['after'] == null ? '삭제' : '수정'} · ${row['recordId']}',
                  ),
                  subtitle: Text(row['created'] as String),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => detail(row),
                ),
              ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('총 ${data.total}건 · ${page + 1}페이지'),
                TextButton(
                  onPressed: page == 0 ? null : () => move(page - 1),
                  child: const Text('이전 이력'),
                ),
                TextButton(
                  onPressed: (page + 1) * 12 >= data.total
                      ? null
                      : () => move(page + 1),
                  child: const Text('다음 이력'),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
