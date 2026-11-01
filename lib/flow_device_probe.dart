import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'data/adaptive_runtime.dart';
import 'data/flow_trace.dart';
import 'data/local_rag.dart';
import 'data/local_summary.dart';
import 'data/local_vision.dart';
import 'data/model_execution.dart';
import 'data/store.dart';
import 'data/system_pilot.dart';
import 'probe_fixture.dart';

Future<void> runFlowDeviceProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('maintenance/device_probe');
  final config = await channel.invokeMapMethod<String, Object?>('config') ?? {};
  final threads = (config['threads'] as int?) ?? 2,
      waitMs = (config['userWaitMs'] as int?) ?? 1000;
  final result = <String, Object?>{
    'moduleName': maintenanceDecisionModuleName,
    'flows': <Map<String, Object?>>[],
  };
  try {
    for (final withLlm in [false, true]) {
      final trace = FlowTrace(), workerResult = <String, Object?>{};
      final runtime = AdaptiveRuntime(
        worker: FlowModelWorker(trace),
        threads: threads,
      );
      AppStore? store;
      var tracing = false;
      try {
        await runtime.initialize();
        final d = runtime.device!;
        result['platform'] = d.isEmulator == true
            ? 'android-emulator'
            : 'android-device';
        result['physicalDevice'] = d.isEmulator == null ? null : !d.isEmulator!;
        result['device'] = {
          'api': d.androidApi,
          'ramBytes': d.totalRamBytes,
          'cores': d.cores,
          'abis': d.abis,
        };
        result['requestedThreads'] = threads;
        store = await oilProbeFixture(
          runtime,
          'DEMO-FLOW-${withLlm ? 'SUMMARY' : 'RETRIEVAL'}',
        );
        final vehicle = store.vehicles.firstWhere(
          (v) => v.id.startsWith('DEMO-FLOW-'),
        );
        final files = File(runtime.modelInfo['indexPath'] as String)
            .parent
            .parent
            .parent;
        final source = File('${files.path}/../cache/vision-public-dog.png');
        final image = File('${files.path}/../cache/flow-captured.png');
        await AndroidModelWorker.channel.invokeMethod<Object?>(
          'startMemoryTrace',
          {'intervalMs': 500},
        );
        tracing = true;
        trace.watch.start();
        await trace.stage('photo_file', () async {
          await source.copy(image.path);
          if (await image.length() == 0) throw StateError('empty image');
        });
        late VisionAnalysis vision;
        await trace.stage('vision', () async {
          // Public stored-file adapter test; camera shutter and permissions are not benchmarked.
          final r = await runtime.manager.run(
            ModelTask.vision,
            runtime.installedModels,
            {'imagePath': image.path},
          );
          if (r.mode != 'model') throw StateError('Vision failed');
          vision = VisionAnalysis.parse(r.output!);
          workerResult['visionTimingsMs'] = r.timingsMs;
        });
        final candidates = visionConceptCandidates(
          vision,
          store.supportLibrary.knowledge,
        );
        if (candidates.isNotEmpty) {
          throw StateError('unreviewed public class mapping');
        }
        final photo = Inspection(
          id: '${vehicle.id}-PHOTO',
          vehicleId: vehicle.id,
          area: '미지정',
          mode: '공개 사진 전체 흐름 시험',
          created: store.clock().toIso8601String(),
          imagePath: image.path,
          note: '가상 확인 · 실차 탐지 평가 아님',
          vision: vision.toJson(),
        );
        await trace.stage('photo_record', () => store!.saveInspection(photo));
        await trace.stage(
          'user_confirmation_wait',
          () => Future<void>.delayed(Duration(milliseconds: waitMs)),
          userWait: true,
        );
        await trace.stage(
          'confirm_part',
          () => store!.saveInspection(
            store.inspections.single,
            confirmedConceptId:
                store.supportLibrary.knowledge.templates.single['conceptId']
                    as String,
          ),
        );
        final confirmed = store.inspections.single;
        const question = '오일필터를 분리할 때 주의할 점을 짧게 알려줘';
        final retrieval = await trace.stage(
          'retrieval',
          () =>
              LocalRag(runtime)
                  .search(store!, vehicle.id, confirmed.area, question),
        );
        if (retrieval.mode != 'hybrid' || retrieval.evidence.length < 2) {
          throw StateError('retrieval failed');
        }
        workerResult['embeddingTimingsMs'] = retrieval.timingsMs;
        if (withLlm) {
          final summary = await trace.stage(
            'llm_summary',
            () => LocalSummary.summarize(
              runtime,
              question,
              retrieval.evidence,
              maxTokens: 128,
            ),
          );
          workerResult['summary'] = {
            'mode': summary.mode,
            'reason': summary.reason,
            'timingsMs': summary.run?.timingsMs,
            'outputTokens': summary.run?.output?['outputTokens'],
          };
          if (summary.run?.mode != 'model') {
            throw StateError('LLM execution failed');
          }
        }
        if (runtime.installedModels.any((m) => m.id == systemPilotId)) {
          final proposal = await trace.stage(
            'system_proposal',
            () => SystemPilot.suggest(runtime, '오일필터를 교환하고 누유를 점검한다.'),
          );
          if (proposal.mode != 'suggestion_only') {
            throw StateError('system pilot proposal failed');
          }
          workerResult['systemProposal'] = {
            'labels': proposal.labels,
            'scores': proposal.scores,
            'timingsMs': proposal.run?.timingsMs,
            'automaticApplication': false,
          };
          await trace.stage(
            'system_confirmation_wait',
            () => Future<void>.delayed(Duration(milliseconds: waitMs)),
            userWait: true,
          );
        }
        await trace.stage(
          'maintenance_save',
          () => store!.addMaintenance(
            Maintenance(
              id: '${vehicle.id}-RECORD',
              vehicleId: vehicle.id,
              date: '2026-10-31',
              part: confirmed.area,
              system: '엔진/연료',
              description: '가상 전체 흐름 확인',
              cost: 0,
              inspectionId: confirmed.id,
            ),
            confirmedConceptId: confirmed.confirmedConceptId,
          ),
        );
        await trace.stage('worker_release', runtime.manager.release);
        trace.watch.stop();
        final saved = store.records.firstWhere(
          (r) => r.inspectionId == confirmed.id,
        );
        if (saved.confirmedConceptId != confirmed.confirmedConceptId ||
            saved.replacementCompleted != null) {
          throw StateError('save linkage failed');
        }
        final memory = await AndroidModelWorker.channel
            .invokeMapMethod<String, Object?>('stopMemoryTrace');
        tracing = false;
        final samples = (memory!['samples'] as List).cast<Map>();
        if (!samples.any(
          (s) =>
              s['validPair'] == true &&
              ((s['worker'] as Map?)?['pssKb'] as num? ?? 0) > 0,
        )) {
          throw StateError('paired memory unavailable');
        }
        (result['flows'] as List).add({
          'withLlm': withLlm,
          ...summarizeFlowTiming(trace.elapsedMs, trace.stages),
          'measurementControlMs': trace.controlMs,
          'stages': trace.stages,
          'modelEvents': trace.modelEvents,
          'memory': memory,
          'outputs': workerResult,
          'recordSaved': true,
          'confirmation': 'scripted manual selection after simulated wait; not measured human reaction time',
          'photo': 'public stored file acquisition, not camera shutter',
          'modelState': 'cold sessions; warm app, caches not flushed',
        });
      } finally {
        if (tracing) {
          await AndroidModelWorker.channel.invokeMethod<Object?>(
            'stopMemoryTrace',
          );
        }
        await runtime.manager.release();
        await store?.db?.close();
        runtime.dispose();
      }
    }
    result['status'] = 'passed';
  } catch (e) {
    result['status'] = 'failed';
    result['error'] = '$e';
  }
  await channel.invokeMethod<Object?>('complete', result);
}
