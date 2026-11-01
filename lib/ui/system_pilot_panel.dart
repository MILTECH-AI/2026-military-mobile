import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/adaptive_runtime.dart';
import '../data/system_pilot.dart';
import '../data/model_execution.dart';
import 'components.dart';

class SystemPilotPanel extends ConsumerStatefulWidget {
  const SystemPilotPanel({
    required this.text,
    required this.identifiers,
    required this.onApply,
    super.key,
  });
  final String text;
  final List<String> identifiers;
  final ValueChanged<String> onApply;
  @override
  ConsumerState<SystemPilotPanel> createState() => _SystemPilotState();
}

class _SystemPilotState extends ConsumerState<SystemPilotPanel> {
  bool busy = false;
  SystemProposal? proposal;
  String? input;
  Future<void> classify() async {
    final text = widget.text;
    setState(() => busy = true);
    try {
      final p = await SystemPilot.suggest(
        ref.read(adaptiveRuntimeProvider),
        text,
        identifiers: widget.identifiers,
      );
      if (mounted && widget.text == text) {
        setState(() {
          proposal = p;
          input = text;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = input == widget.text ? proposal : null;
    return Panel(
      title: '정비기록 분류 · 계통 제안',
      subtitle:
          '$maintenanceDecisionModuleName\n단일 AI 라벨 초안 · 사람 독립 검토 없음 · 원자료 작성 경위 미확인',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('정비 내용만 분석합니다. 점수는 검증된 확률이 아니며 저장 계통은 자동 변경되지 않습니다.'),
          TextButton(
            key: const ValueKey('system-pilot-run'),
            onPressed: busy || widget.text.trim().isEmpty ? null : classify,
            child: Text(busy ? '계통 제안 계산 중…' : '계통 제안 받기'),
          ),
          if (p != null && p.mode != 'suggestion_only')
            const Text('제안을 사용할 수 없습니다. 정비 계통을 직접 선택해 주세요.'),
          if (p?.mode == 'suggestion_only')
            for (var i = 0; i < p!.labels.length; i++)
              TextButton(
                key: ValueKey('system-pilot-apply-${p.labels[i]}'),
                onPressed: () => widget.onApply(p.labels[i]),
                child: Text(
                  '${p.labels[i]} · 모델 점수 ${p.scores[i].toStringAsFixed(3)} · 이 계통 선택',
                ),
              ),
        ],
      ),
    );
  }
}
