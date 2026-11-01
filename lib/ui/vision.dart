import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../data/store.dart';
import '../data/adaptive_runtime.dart';
import 'components.dart';
import 'support.dart';
import 'vision_runtime.dart';

class VisionScreen extends ConsumerStatefulWidget {
  const VisionScreen({this.vehicleId, this.sessionId, this.part, super.key});
  final String? vehicleId;
  final String? sessionId;
  final String? part;
  @override
  ConsumerState<VisionScreen> createState() => _VisionState();
}

class _VisionState extends ConsumerState<VisionScreen>
    with WidgetsBindingObserver {
  int step = 0;
  String mode = '차량 촬영', area = '외관';
  String? vehicle, cameraError, imagePath, selectedSession;
  CameraController? controller;
  bool initializing = false, capturing = false, saving = false, paused = false;
  int cameraGeneration = 0;
  final annotation = TextEditingController();
  @override
  void initState() {
    super.initState();
    if (widget.part != null && widget.part!.isNotEmpty) {
      area = standardPart(widget.part!);
      mode = '부품 촬영';
    }
    if (widget.sessionId != null) {
      selectedSession = widget.sessionId;
      step = 4;
    }
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cameraGeneration++;
    controller?.dispose();
    annotation.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      cameraGeneration++;
      final old = controller;
      controller = null;
      old?.dispose();
      if (mounted) setState(() => initializing = false);
    } else if (state == AppLifecycleState.resumed && step == 2) {
      startCamera();
    }
  }

  Future<void> startCamera() async {
    final runtime = ref.read(adaptiveRuntimeProvider);
    await runtime.refreshDevice();
    if (!mounted) return;
    if (runtime.device?.cameraBlocked == true) {
      cameraGeneration++;
      final old = controller;
      controller = null;
      await old?.dispose();
      if (!mounted) return;
      runtime.cameraFailed();
      setState(
        () =>
            cameraError = '기기 정책 또는 하드웨어로 카메라를 사용할 수 없습니다. 수동 부품 선택을 이용해 주세요.',
      );
      return;
    }
    final generation = ++cameraGeneration;
    final old = controller;
    controller = null;
    await old?.dispose();
    if (!mounted) return;
    setState(() {
      initializing = true;
      cameraError = null;
      paused = false;
    });
    CameraController? next;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('camera unavailable');
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      next = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await next.initialize();
      if (!mounted || generation != cameraGeneration) {
        await next.dispose();
        return;
      }
      setState(() => controller = next);
      runtime.cameraOpened();
    } catch (e) {
      runtime.cameraFailed();
      await next?.dispose();
      if (mounted && generation == cameraGeneration) {
        setState(
          () => cameraError =
              e is CameraException &&
                  (e.code.contains('AccessDenied') ||
                      e.code.contains('Permission'))
              ? '카메라 권한이 필요합니다. 기기 설정에서 카메라 권한을 허용한 후 다시 연결해 주세요.'
              : '카메라에 연결할 수 없습니다. 수동 부품 선택을 이용하거나 카메라를 재연결해 주세요.',
        );
      }
    } finally {
      if (mounted && generation == cameraGeneration) {
        setState(() => initializing = false);
      }
    }
  }

  Future<void> capture() async {
    if (controller == null || !controller!.value.isInitialized || capturing) {
      return;
    }
    setState(() => capturing = true);
    try {
      final photo = await controller!.takePicture();
      final folder = await getApplicationDocumentsDirectory();
      final images = Directory('${folder.path}/inspection_images');
      await images.create(recursive: true);
      final path =
          '${images.path}/${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(photo.path).copy(path);
      cameraGeneration++;
      await controller?.dispose();
      controller = null;
      if (mounted) {
        setState(() {
          imagePath = path;
          step = 3;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('촬영하지 못했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => capturing = false);
    }
  }

  Future<void> save() async {
    if (imagePath == null || saving) return;
    setState(() => saving = true);
    try {
      final s = ref.read(storeProvider);
      final id = s.newId('VS');
      await s.saveInspection(
        Inspection(
          id: id,
          vehicleId: vehicle!,
          area: area,
          mode: mode,
          created: DateTime.now().toIso8601String(),
          imagePath: imagePath!,
          note: annotation.text.trim(),
        ),
      );
      if (mounted) {
        setState(() {
          selectedSession = id;
          step = 4;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('점검 기록을 저장하지 못했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    vehicle ??= s.vehicles.any((v) => v.id == widget.vehicleId)
        ? widget.vehicleId
        : s.activeVehicles.first.id;
    return ListView(
      children: [
        PageTitle(
          ['비전 점검', '대상 지정', '실시간 촬영', '촬영 결과', '세션 기록'][step],
          [
            '차량 또는 부품을 촬영하여 상태를 점검합니다.',
            '점검할 장비번호와 부위를 선택합니다.',
            '차량 정면을 중앙선에 맞춰 주세요.',
            '촬영한 원본과 현장 점검 내용을 기록합니다.',
            '저장된 원본 프레임과 점검 기록을 확인합니다.',
          ][step],
          scopeVehicles: [s.vehicle(vehicle!)],
          action: step == 0
              ? TextButton(
                  onPressed: () => setState(() => step = 4),
                  child: const Text('세션 기록'),
                )
              : null,
        ),
        if (ref.watch(adaptiveRuntimeProvider).cameraBlocked && step < 4)
          Panel(
            title: '카메라 사용 불가 · 수동 부품 선택',
            subtitle: 'Vision은 꺼집니다. 사진 없이 근거·이력 조회와 정비 등록을 계속할 수 있습니다.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('manual-vehicle-without-camera'),
                  initialValue: vehicle,
                  decoration: const InputDecoration(labelText: '차량 선택'),
                  items: s.vehicles
                      .map(
                        (v) => DropdownMenuItem(
                          value: v.id,
                          child: Text('${v.id} · ${v.model}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => vehicle = v ?? vehicle),
                ),
                DropdownButtonFormField<String>(
                  key: const ValueKey('manual-part-without-camera'),
                  initialValue: area,
                  decoration: const InputDecoration(labelText: '부품 선택'),
                  items:
                      {
                            area,
                            ...standardParts.keys,
                            ...s.supportLibrary.knowledge.concepts.map(
                              (c) => c['name'] as String,
                            ),
                          }
                          .map(
                            (p) => DropdownMenuItem(value: p, child: Text(p)),
                          )
                          .toList(),
                  onChanged: (v) => setState(() => area = v ?? area),
                ),
                FilledButton(
                  key: const ValueKey('manual-part-support'),
                  onPressed: () => context.go(supportUrl(vehicle!, area)),
                  child: const Text('선택 부품의 근거·이력 확인'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() => step = 2);
                    startCamera();
                  },
                  child: const Text('카메라 사용 조건 다시 확인'),
                ),
              ],
            ),
          )
        else if (step == 0)
          _mode()
        else if (step == 1)
          _target(s)
        else if (step == 2)
          _live()
        else if (step == 3)
          _result()
        else
          _sessions(s),
      ],
    );
  }

  Widget _mode() => Panel(
    title: '점검할 대상을 선택해 주세요',
    subtitle: '선택한 대상에 맞는 촬영 가이드가 제공됩니다.',
    child: Column(
      children: [
        ResponsiveColumns(
          breakpoint: 600,
          children: [
            for (final value in ['차량 촬영', '부품 촬영'])
              InkWell(
                onTap: () => setState(() => mode = value),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: 290,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: mode == value
                        ? const Color(0xFFECFBF3)
                        : Colors.white,
                    border: Border.all(
                      color: mode == value ? green : line,
                      width: mode == value ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: cell(
                          mode == value ? '● 선택됨' : '선택 가능',
                          color: mode == value ? green : muted,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: value == '차량 촬영'
                              ? const Color(0xFFDDF7E8)
                              : const Color(0xFFF8F9FA),
                          border: Border.all(
                            color: value == '차량 촬영' ? green : line,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            DesignIcon(
                              '1:2446',
                              value == '차량 촬영' ? 'imgCamera' : 'imgCamera1',
                              size: 44,
                            ),
                            Positioned(
                              right: 10,
                              bottom: 10,
                              child: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: value == '차량 촬영' ? green : line,
                                  ),
                                ),
                                child: Center(
                                  child: DesignIcon(
                                    '1:2446',
                                    value == '차량 촬영' ? 'imgTruck' : 'imgWrench',
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        value,
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        value == '차량 촬영'
                            ? '차량 전면·측면을 촬영하여 외관 상태를 기록합니다.'
                            : '정비 대상 부품을 가까이 촬영하여 상태를 기록합니다.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        note('충분한 조명을 확보하고, 차량 또는 부품 전체가 촬영 가이드 안에 들어오도록 유지해 주세요.'),
        const SizedBox(height: 40),
        Row(
          children: [
            Expanded(child: cell('현재 선택 · $mode', bold: true)),
            FilledButton.icon(
              onPressed: () => setState(() => step = 1),
              icon: const DesignIcon('1:2446', 'imgCamera2'),
              label: const Text('시작하기'),
            ),
          ],
        ),
      ],
    ),
  );
  Widget _target(AppStore s) => Panel(
    title: '점검 대상을 확인해 주세요',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('장비번호 *', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
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
          onChanged: (v) => setState(() => vehicle = v),
        ),
        const SizedBox(height: 28),
        const Text('점검 부위', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children:
              {'외관', '차체', '창문', '조명', '하부', '엔진룸', ...standardParts.keys, area}
                  .map(
                    (a) => ChoiceChip(
                      label: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(a),
                      ),
                      selected: area == a,
                      onSelected: (_) => setState(() => area = a),
                    ),
                  )
                  .toList(),
        ),
        const SizedBox(height: 28),
        note('주변 안전을 확보하고 장비가 정차된 상태인지 확인해 주세요.'),
        const SizedBox(height: 48),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () => setState(() => step = 0),
              child: const Text('이전'),
            ),
            FilledButton.icon(
              onPressed: () {
                setState(() => step = 2);
                startCamera();
              },
              icon: const DesignIcon('1:2565', 'imgCamera'),
              label: const Text('촬영 시작'),
            ),
          ],
        ),
      ],
    ),
  );
  Widget _live() => Panel(
    title: '$vehicle · $area',
    subtitle: '카메라 촬영 · AI 판정 모델 미연결',
    child: Column(
      children: [
        ResponsiveColumns(
          flexes: const [2, 1],
          breakpoint: 850,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: const Color(0xFF131A1C)),
                    if (controller != null && controller!.value.isInitialized)
                      Center(
                        child: AspectRatio(
                          aspectRatio: controller!.value.aspectRatio,
                          child: CameraPreview(controller!),
                        ),
                      )
                    else if (initializing)
                      const Center(child: CircularProgressIndicator())
                    else
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const DesignIcon('1:2728', 'img11', size: 210),
                          Padding(
                            padding: const EdgeInsets.all(22),
                            child: Text(
                              cameraError ?? '카메라 연결 대기',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: startCamera,
                            child: const Text('카메라 다시 연결'),
                          ),
                        ],
                      ),
                    IgnorePointer(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: green.withValues(alpha: .65),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 14,
                      left: 14,
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        color: ink,
                        child: Text(
                          controller == null ? 'Figma 촬영 가이드 예시' : '● 카메라 미리보기',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Column(
              children: [
                Panel(
                  title: '부품 식별 상태',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final p in [
                        '전조등',
                        '전면 범퍼',
                        '타이어',
                        '라디에이터 그릴',
                        '차체 패널',
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          child: Row(
                            children: [
                              Expanded(child: cell(p, bold: true)),
                              cell('자동 식별 미연결', color: muted),
                            ],
                          ),
                        ),
                      note(
                        '영상 자동 인식 모델 연결 전입니다. 점검 대상을 수동 지정하고 관련 정비 근거로 연결합니다. 고장 여부는 담당자가 확인합니다.',
                        color: Colors.orange,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () async {
                cameraGeneration++;
                await controller?.dispose();
                controller = null;
                if (mounted) setState(() => step = 1);
              },
              child: const Text('대상 변경'),
            ),
            OutlinedButton.icon(
              onPressed: controller == null
                  ? null
                  : () async {
                      try {
                        if (paused) {
                          await controller!.resumePreview();
                        } else {
                          await controller!.pausePreview();
                        }
                        if (mounted) setState(() => paused = !paused);
                      } catch (_) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('미리보기 상태를 변경하지 못했습니다.'),
                            ),
                          );
                        }
                      }
                    },
              icon: const DesignIcon('1:2728', 'imgPause'),
              label: Text(paused ? '미리보기 재개' : '화면 고정'),
            ),
            FilledButton.icon(
              onPressed: controller == null || capturing ? null : capture,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(capturing ? '촬영 중…' : '촬영 및 기록'),
            ),
          ],
        ),
      ],
    ),
  );
  Widget _result() => Panel(
    title: '촬영 결과 · 수동 점검',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveColumns(
          flexes: const [2, 1],
          children: [
            if (imagePath != null)
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.file(File(imagePath!), fit: BoxFit.contain),
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                note(
                  '수동 지정 부품: ${standardPart(area)} · 영상 자동 인식 없음',
                  color: Colors.orange,
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: annotation,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '점검 메모',
                    hintText: '점검 부위, 관찰한 상태, 후속 조치 등을 입력',
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () {
                setState(() => step = 2);
                startCamera();
              },
              child: const Text('다시 촬영'),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving ? '저장 중…' : '세션 기록 저장'),
            ),
          ],
        ),
      ],
    ),
  );
  Widget _sessions(AppStore s) {
    final records = s.inspections.where((i) => i.vehicleId == vehicle).toList();
    final selected =
        records.where((i) => i.id == selectedSession).firstOrNull ??
        records.firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Panel(
          title: '저장된 점검 세션',
          subtitle: '차량 $vehicle · ${records.length}건',
          action: TextButton(
            onPressed: () => setState(() => step = 0),
            child: const Text('새 점검'),
          ),
          child: records.isEmpty
              ? empty('아직 저장된 촬영 기록이 없습니다.')
              : Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: records
                      .map(
                        (i) => SizedBox(
                          width: 190,
                          child: InkWell(
                            onTap: () => setState(() => selectedSession = i.id),
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: selected?.id == i.id ? green : line,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    height: 125,
                                    child: Image.file(
                                      File(i.imagePath),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, e, stack) =>
                                          const Center(child: Text('원본 파일 없음')),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        cell(i.area, bold: true),
                                        cell(
                                          i.created
                                              .substring(0, 16)
                                              .replaceAll('T', ' '),
                                          color: muted,
                                        ),
                                        cell(
                                          i.vision == null
                                              ? '수동 점검 · AI 미판정'
                                              : i.confirmedConceptId == null
                                              ? '공개 모델 시험 · 개념 미확인'
                                              : '공개 모델 시험 · 사용자 개념 확인',
                                          color: muted,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 16),
          if (ref
              .watch(adaptiveRuntimeProvider)
              .installedModels
              .any((m) => m.id == 'ssd-mobilenet-int8-public-v1')) ...[
            VisionRuntimePanel(inspection: selected),
            const SizedBox(height: 16),
          ],
          Panel(
            title: '점검 기록 상세',
            subtitle: selected.id,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cell(
                  '차량 ${selected.vehicleId} · ${selected.mode} · ${selected.area}',
                  bold: true,
                ),
                const SizedBox(height: 12),
                Text(selected.note.isEmpty ? '점검 메모 없음' : selected.note),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: () => context.go(
                        supportUrl(
                          selected.vehicleId,
                          selected.area,
                          selected.id,
                        ),
                      ),
                      child: const Text('부품 근거·정비 이력 연결'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          context.go('/vehicles/${selected.vehicleId}'),
                      child: const Text('차량 상세로 이동'),
                    ),
                    FilledButton(
                      onPressed: () => context.go(
                        Uri(
                          path: '/entry',
                          queryParameters: {
                            'vehicle': selected.vehicleId,
                            'inspection': selected.id,
                          },
                        ).toString(),
                      ),
                      child: const Text('정비 기록 등록'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
