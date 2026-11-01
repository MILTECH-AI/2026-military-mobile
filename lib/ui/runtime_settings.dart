import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'dart:io';

import '../data/adaptive_runtime.dart';
import '../data/model_execution.dart';
import '../data/store.dart';
import 'components.dart';

class RuntimeSettingsPanel extends ConsumerWidget {
  const RuntimeSettingsPanel({super.key});
  String tierName(ModelTier t) => switch (t) {
    ModelTier.basic => '기본',
    ModelTier.enhanced => '확장',
    ModelTier.generation => '생성',
  };
  String gib(int bytes) =>
      '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(adaptiveRuntimeProvider);
    final d = r.device;
    return Panel(
      title: '기기 사양·모델 단계',
      subtitle: '측정 근거가 있는 단계만 자동 선택 · 사용자는 하향 선택 가능',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d != null)
            Text(
              'RAM ${gib(d.totalRamBytes)} · 가용 ${gib(d.availableRamBytes)}\n'
              'CPU ${d.cores}코어 · ${d.abis.join(', ')} · Android API ${d.androidApi}\n'
              '앱 저장공간 여유 ${gib(d.freeStorageBytes)}${d.lowMemory ? ' · 시스템 저메모리 상태' : ''}',
            ),
          if (r.detectionError != null) Text(r.detectionError!),
          Text(
            '카메라: ${r.cameraOpenFailed ? '실제 연결 실패' : d?.cameraStatusLabel ?? '확인 불가'} · 사용 불가 시 수동 부품 선택',
          ),
          Text(
            '현재: ${tierName(r.selectedTier)} · LLM ${r.generationEnabled ? '켜짐' : '꺼짐 (retrieval_only)'}',
          ),
          const Text(
            '모델 단계 기준: 실측 전 미확정. 현재 기본 단계는 보수적 선택이며 최소 사양 검증 결과가 아닙니다.',
          ),
          const Text(maintenanceDecisionModuleName),
          Text(
            r.installedModels.isEmpty
                ? '실제 Vision·임베딩·정비기록 분류·LLM 모델: 미등록. 기존 예제 모델은 별도입니다.'
                : '설치 모델: ${r.installedModels.map((m) => m.id).join(' · ')} · 잔여 정비거리는 등록 규칙으로 계산',
          ),
          TextButton(
            onPressed: () async {
              const channel = MethodChannel('maintenance/local_files');
              String? path;
              try {
                path = await channel.invokeMethod<String>('pickEmbedding');
                if (path == null) return;
                await r.installEmbedding(path);
                final knowledgePath = r.modelInfo['knowledgePath'] as String;
                final bundle = KnowledgeBundle.decode(
                  await File(knowledgePath).readAsString(),
                );
                if (!context.mounted) return;
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('임베딩 모델 설치 완료 · 근거 반입 확인'),
                    content: Text(
                      '문서 근거 ${bundle.library.evidence.length}개 · 검토 대기 실적 ${bundle.library.knowledge.pending.length}건\n품번과 차량 적용조건은 별도로 확인합니다. 근거도 반입하시겠습니까?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('근거 반입 취소'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('근거 반입'),
                      ),
                    ],
                  ),
                );
                if (yes == true) {
                  await ref.read(storeProvider).importKnowledge(bundle);
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        yes == true
                            ? '임베딩 모델과 근거를 반입했습니다. 차량 적용조건을 확인해 주세요.'
                            : '모델은 설치됐습니다. 기존 근거에 맞는 색인이 없으면 키워드 검색을 유지합니다.',
                      ),
                    ),
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('반입하지 못했습니다. 파일·공간·기존 반입 ID를 확인해 주세요.'),
                    ),
                  );
                }
              } finally {
                if (path != null) {
                  await channel.invokeMethod<bool>('releaseBackup', {
                    'path': path,
                  });
                }
              }
            },
            child: const Text('로컬 임베딩 묶음 반입 (.mrag)'),
          ),
          TextButton(
            onPressed: () async {
              const channel = MethodChannel('maintenance/local_files');
              String? path;
              try {
                path = await channel.invokeMethod<String>('pickBackup');
                if (path == null) return;
                await r.installVision(path);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        '공개 Vision 모델을 반입했습니다. 렉스턴 부품 성능 검증용이 아닙니다.',
                      ),
                    ),
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Vision 모델 반입 실패: 파일·해시·공간을 확인해 주세요.'),
                    ),
                  );
                }
              } finally {
                if (path != null) {
                  await channel.invokeMethod<bool>('releaseBackup', {
                    'path': path,
                  });
                }
              }
            },
            child: const Text('공개 Vision 모델 반입 (SSD MobileNet INT8)'),
          ),
          if ((d?.androidApi ?? 0) >= 28)
            TextButton(
              onPressed: () async {
                const channel = MethodChannel('maintenance/local_files');
                String? path;
                try {
                  path = await channel.invokeMethod<String>('pickLlm');
                  if (path == null) return;
                  await r.installLlm(path);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '선택 LLM을 반입했습니다. 자동 단계는 변경하지 않습니다. 정비지원 화면에서 요약 시험을 선택할 수 있습니다.',
                        ),
                      ),
                    );
                  }
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'LLM 반입 실패: API·64비트 ABI·파일·공간을 확인해 주세요. 원문 검색을 유지합니다.',
                        ),
                      ),
                    );
                  }
                } finally {
                  if (path != null) {
                    await channel.invokeMethod<bool>('releaseBackup', {
                      'path': path,
                    });
                  }
                }
              },
              child: const Text('선택 LLM 반입 (Qwen3-0.6B Q4_0 .gguf)'),
            ),
          TextButton(
            onPressed: () async {
              const channel = MethodChannel('maintenance/local_files');
              String? path;
              try {
                path = await channel.invokeMethod<String>('pickBackup');
                if (path == null) return;
                await r.installSystemPilot(path);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        '단일 초안·출처 미확인 계통 분류 파일럿을 반입했습니다. 결과는 제안으로만 표시합니다.',
                      ),
                    ),
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('파일럿 모델 반입 실패: 형식·출처 표시·파일 해시를 확인해 주세요.'),
                    ),
                  );
                }
              } finally {
                if (path != null) {
                  await channel.invokeMethod<bool>('releaseBackup', {
                    'path': path,
                  });
                }
              }
            },
            child: const Text('계통 분류 파일럿 반입 (.msystem)'),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('runtime-ceiling-${r.userCeiling?.name}'),
            initialValue: r.userCeiling?.name ?? 'auto',
            decoration: const InputDecoration(labelText: '모델 단계 상한'),
            items: [
              const DropdownMenuItem(value: 'auto', child: Text('자동')),
              for (final t in ModelTier.values.where(
                (t) => t.index <= r.automaticTier.index || t == r.userCeiling,
              ))
                DropdownMenuItem(value: t.name, child: Text(tierName(t))),
            ],
            onChanged: (v) => r.setCeiling(
              ModelTier.values.where((t) => t.name == v).firstOrNull,
            ),
          ),
          if (r.settingsError != null) Text(r.settingsError!),
          TextButton(
            onPressed: r.refreshDevice,
            child: const Text('가용 사양 다시 확인'),
          ),
        ],
      ),
    );
  }
}
