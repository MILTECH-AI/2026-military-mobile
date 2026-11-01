import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/adaptive_runtime.dart';
import '../data/local_vision.dart';
import '../data/model_execution.dart';
import '../data/store.dart';
import 'components.dart';
import 'support.dart';

class VisionRuntimePanel extends ConsumerStatefulWidget {
  const VisionRuntimePanel({required this.inspection, super.key});
  final Inspection inspection;
  @override
  ConsumerState<VisionRuntimePanel> createState() => _VisionRuntimeState();
}

class _VisionRuntimeState extends ConsumerState<VisionRuntimePanel> {
  bool busy = false, confirmed = false;
  String? selection, error;
  @override
  void didUpdateWidget(covariant VisionRuntimePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inspection.id != widget.inspection.id ||
        oldWidget.inspection.imagePath != widget.inspection.imagePath) {
      selection = null;
      confirmed = false;
      error = null;
    }
  }

  Future<void> detect() async {
    setState(() => busy = true);
    try {
      final i = widget.inspection;
      final result = await ref.read(adaptiveRuntimeProvider).run(
        ModelTask.vision,
        {'imagePath': i.imagePath},
      );
      if (result.mode != 'model') throw StateError('vision_unavailable');
      final analysis = VisionAnalysis.parse(result.output!);
      final store = ref.read(storeProvider);
      final current = store.inspections
          .where((x) => x.id == i.id && x.imagePath == i.imagePath)
          .firstOrNull;
      if (current == null) return;
      await store.saveInspection(
        Inspection.fromJson({
          ...current.toJson(),
          'vision': {
            ...analysis.toJson(),
            'analysedAt': store.clock().toIso8601String(),
          },
        }),
      );
      if (mounted) {
        setState(() {
          selection = null;
          confirmed = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = '탐지 결과를 사용할 수 없습니다. 수동 부품 선택으로 계속할 수 있습니다.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!confirmed || selection == null) return;
    setState(() => busy = true);
    try {
      await ref
          .read(storeProvider)
          .saveInspection(widget.inspection, confirmedConceptId: selection);
      if (mounted) setState(() => confirmed = false);
    } catch (_) {
      if (mounted) setState(() => error = '부품 개념 확인을 저장하지 못했습니다.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = ref.watch(adaptiveRuntimeProvider),
        store = ref.watch(storeProvider),
        i = widget.inspection;
    VisionAnalysis? analysis;
    try {
      if (i.vision != null) analysis = VisionAnalysis.parse(i.vision!);
    } catch (_) {}
    final candidates = analysis == null
        ? <Map<String, dynamic>>[]
        : visionConceptCandidates(analysis, store.supportLibrary.knowledge);
    final concepts = store.supportLibrary.knowledge.concepts;
    return Panel(
      title: '공개 Vision 실행 시험 · 부품 개념 확인',
      subtitle: '렉스턴 부품 탐지 성능은 검증하지 않았습니다. 탐지 클래스는 자동 확정되지 않습니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton(
            onPressed:
                busy ||
                    runtime.cameraBlocked ||
                    runtime.device?.cameraAvailable != true
                ? null
                : detect,
            child: Text(busy ? '모델 작업 중…' : '저장 이미지로 공개 탐지 모델 시험'),
          ),
          if (runtime.cameraBlocked || runtime.device?.cameraAvailable != true)
            const Text('카메라 사용 조건 미충족 · Vision 실행을 끄고 수동 부품 선택을 유지합니다.'),
          if (error != null) Text(error!),
          if (analysis != null) ...[
            for (final d in analysis.detections)
              Text(
                'COCO ${d.classId} · ${d.label} · 모델 점수 ${d.score.toStringAsFixed(3)}',
              ),
            if (candidates.isEmpty)
              const Text('확인된 부품 개념 대응이 없습니다. 아래에서 수동 선택해 주세요.'),
            if (candidates.isNotEmpty)
              Text(
                '개념 후보: ${candidates.map((c) => c['name']).join(' · ')} · 사용자 확인 필요',
              ),
          ],
          if (i.confirmedConceptId != null)
            Text('사용자 확인 완료: ${i.area} · ${i.conceptConfirmedAt}'),
          if (concepts.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              key: ValueKey('vision-concept-${i.id}-$selection'),
              initialValue: selection,
              decoration: const InputDecoration(labelText: '부품 개념 수동 선택'),
              items: [
                for (final c in concepts)
                  DropdownMenuItem(
                    value: c['id'] as String,
                    child: Text(c['name'] as String),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      selection = v;
                      confirmed = false;
                    }),
            ),
            CheckboxListTile(
              key: const ValueKey('vision-confirm-concept'),
              contentPadding: EdgeInsets.zero,
              title: const Text('이 점검 사진과 선택한 부품 개념의 연결을 확인했습니다'),
              subtitle: const Text('품번·적용조건 확정이나 모델의 자동 판정이 아닙니다.'),
              value: confirmed,
              onChanged: selection == null || busy
                  ? null
                  : (v) => setState(() => confirmed = v == true),
            ),
            FilledButton(
              key: const ValueKey('vision-save-concept'),
              onPressed: !confirmed || busy ? null : save,
              child: const Text('부품 개념 확인 저장'),
            ),
          ],
          if (i.confirmedConceptId != null)
            TextButton(
              onPressed: () =>
                  context.go(supportUrl(i.vehicleId, i.area, i.id)),
              child: const Text('확인한 부품 → 근거·이력 조회'),
            ),
        ],
      ),
    );
  }
}
