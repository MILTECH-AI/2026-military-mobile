import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/store.dart';
import 'components.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({this.vehicleId, super.key});
  final String? vehicleId;
  @override
  ConsumerState<ChatScreen> createState() => _ChatState();
}

class _ChatState extends ConsumerState<ChatScreen> {
  final question = TextEditingController();
  String? vehicle, answer;
  bool sending = false;
  int tab = 0;
  @override
  void dispose() {
    question.dispose();
    super.dispose();
  }

  Future<void> ask() async {
    if (question.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('증상을 입력해 주세요.')));
      return;
    }
    setState(() => sending = true);
    try {
      await ref
          .read(storeProvider)
          .saveQuestion(vehicle!, question.text.trim());
      if (mounted) setState(() => answer = question.text.trim());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('질문 기록을 저장하지 못했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(storeProvider);
    vehicle ??= s.vehicles.any((v) => v.id == widget.vehicleId)
        ? widget.vehicleId
        : s.vehicles.first.id;
    return ListView(
      children: [
        const PageTitle('정비지원 챗봇', '고장 증상과 정비 이력을 연결하여 정비를 지원합니다.'),
        note(
          '교범과 답변 생성 모델을 연결하기 전입니다. 질문 저장·관련 정비이력 조회를 사용할 수 있으며, 실제 AI 답변이나 교범 인용은 생성하지 않습니다.',
          color: Colors.orange,
        ),
        const SizedBox(height: 16),
        if (answer == null)
          ResponsiveColumns(
            breakpoint: 850,
            flexes: const [1, 2],
            children: [
              Panel(
                title: '최근 질문',
                subtitle: '기기에 저장된 질문 기록',
                child: s.questions.isEmpty
                    ? empty('저장된 질문이 없습니다.')
                    : Column(
                        children: s.questions
                            .take(6)
                            .map(
                              (q) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  q['question'],
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                subtitle: Text(
                                  '${q['vehicleId']} · ${q['created'].toString().substring(0, 10)}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onTap: () => setState(() {
                                  vehicle = q['vehicleId'];
                                  answer = q['question'];
                                }),
                              ),
                            )
                            .toList(),
                      ),
              ),
              Panel(
                title: '새 질문',
                subtitle: '발생 시점, 계기판 표시, 소음·진동 여부를 함께 입력해 주세요.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                    const SizedBox(height: 16),
                    TextField(
                      controller: question,
                      maxLines: 8,
                      maxLength: 1000,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '증상 입력',
                        hintText: '예) 시동이 걸리지 않습니다.',
                      ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: sending ? null : ask,
                      icon: const DesignIcon('1:3389', 'imgArrowUp'),
                      label: Text(sending ? '저장 중…' : '질문 기록 및 관련 이력 보기'),
                    ),
                    const SizedBox(height: 18),
                    note('현장 점검과 실제 조치는 정비 담당자의 확인이 필요합니다.'),
                  ],
                ),
              ),
            ],
          )
        else ...[
          ResponsiveColumns(
            breakpoint: 850,
            flexes: const [3, 2],
            children: [
              Panel(
                title: '질문 및 지원 상태',
                subtitle: '차량 $vehicle · 기기 내 저장',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    note(answer!),
                    const SizedBox(height: 20),
                    const Row(
                      children: [
                        DesignIcon('1:3552', 'imgBot', size: 26),
                        SizedBox(width: 10),
                        Text(
                          '정비지원 AI',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '답변 생성 대기',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '실제 교범과 모델이 연결되면 근거가 있는 답변을 표시합니다. 현재는 관련 차량의 저장된 정비 기록을 확인할 수 있습니다.',
                      style: TextStyle(color: muted, height: 1.8),
                    ),
                    const SizedBox(height: 24),
                    note(
                      '교범 원문이 없어 문서명·페이지를 임의로 인용하지 않습니다.',
                      color: Colors.orange,
                    ),
                  ],
                ),
              ),
              Panel(
                title: tab == 0 ? '근거 교범' : '관련 정비이력',
                action: Wrap(
                  children: [
                    TextButton(
                      onPressed: () => setState(() => tab = 0),
                      child: const Text('교범'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => tab = 1),
                      child: const Text('이력'),
                    ),
                  ],
                ),
                child: tab == 0
                    ? empty('등록된 교범이 없습니다.')
                    : s.history(vehicle!).isEmpty
                    ? empty('관련 정비 기록이 없습니다.')
                    : Column(
                        children: s
                            .history(vehicle!)
                            .map(
                              (r) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  r.part,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  '${r.date}\n${r.description}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                isThreeLine: true,
                                onTap: () => context.go('/records/${r.id}'),
                              ),
                            )
                            .toList(),
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
                  onPressed: () => setState(() {
                    answer = null;
                    question.clear();
                  }),
                  icon: const DesignIcon('1:3552', 'imgMessageCirclePlus'),
                  label: const Text('추가 질문'),
                ),
                OutlinedButton.icon(
                  onPressed: () => context.go('/vehicles/$vehicle'),
                  icon: const DesignIcon('1:3552', 'imgTruck1'),
                  label: const Text('차량 상세 보기'),
                ),
                FilledButton.icon(
                  onPressed: () => context.go('/entry?vehicle=$vehicle'),
                  icon: const DesignIcon('1:3552', 'imgClipboardPlus'),
                  label: const Text('정비 기록 등록'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
