import 'dart:convert';
import 'dart:io';

import 'adaptive_runtime.dart';
import 'model_execution.dart';

const systemPilotId = 'maintenance-system-pilot-v1';
const systemFeatureConfig = 'hash-char-binary-fnv1a32-v1';
const maintenanceSystems = {
  '엔진/연료',
  '흡기/배기',
  '냉각',
  '제동',
  '조향/현가',
  '동력전달',
  '공조',
  '차체',
  '전장',
};
String normalizeSystemText(
  String text, {
  Iterable<String> identifiers = const [],
}) {
  final ids = identifiers.where((s) => s.trim().length >= 2).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final id in ids) {
    text = text.replaceAll(id, ' ');
  }
  return text
      .replaceAll(r'\r\n', ' ')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z가-힣ㄱ-ㅎㅏ-ㅣ ]'), ' ')
      .replaceAll(RegExp(' +'), ' ')
      .trim();
}

List<int> systemFeatureIds(String normalized) {
  if (normalized.isEmpty) return [];
  final text = '^$normalized\$';
  final ids = <int>{};
  for (final n in [2, 3, 4]) {
    for (var at = 0; at + n <= text.length; at++) {
      var hash = 2166136261;
      for (final byte in utf8.encode(text.substring(at, at + n))) {
        hash = ((hash ^ byte) * 16777619) & 0xffffffff;
      }
      ids.add(hash % 4096);
    }
  }
  return ids.toList()..sort();
}

class SystemProposal {
  const SystemProposal(
    this.mode, {
    this.labels = const [],
    this.scores = const [],
    this.reason,
    this.run,
  });
  final String mode;
  final List<String> labels;
  final List<double> scores;
  final String? reason;
  final ModelRunResult? run;
}

class SystemPilot {
  static Future<SystemProposal> suggest(
    AdaptiveRuntime runtime,
    String text, {
    Iterable<String> identifiers = const [],
  }) async {
    if (text.runes.length > 2000) {
      return const SystemProposal('unavailable', reason: 'input_too_long');
    }
    final normalized = normalizeSystemText(text, identifiers: identifiers),
        ids = systemFeatureIds(
          normalizeSystemText(text, identifiers: identifiers),
        );
    if (normalized.isEmpty || ids.isEmpty) {
      return const SystemProposal('unavailable', reason: 'empty_features');
    }
    await runtime.initialize();
    final info = runtime.modelInfo['systemPilot'] as Map?;
    if (info?['installed'] != true) {
      return const SystemProposal('unavailable', reason: 'pilot_not_installed');
    }
    try {
      final file = File(info!['metadataPath'] as String);
      if (await file.length() > 2 * 1024 * 1024) {
        throw const FormatException('metadata_limit');
      }
      final meta = jsonDecode(await file.readAsString()) as Map;
      if (meta['modelId'] != systemPilotId ||
          meta['featureConfig'] != systemFeatureConfig ||
          meta['sourceStatus'] != 'authorship_unconfirmed' ||
          meta['labelStatus'] != 'single_ai_draft_not_human_reviewed' ||
          meta['use'] != 'suggestion_only') {
        throw const FormatException('provenance_mismatch');
      }
      final labels = List<String>.from(meta['labels'] as List);
      if (labels.length != 9 ||
          labels.toSet().length != 9 ||
          !maintenanceSystems.containsAll(labels)) {
        throw const FormatException('labels_mismatch');
      }
      final seen = Set<int>.from(meta['seenFeatureIds'] as List);
      if (!ids.any(seen.contains)) {
        return const SystemProposal('unavailable', reason: 'no_seen_features');
      }
      final vector = List<double>.filled(4096, 0);
      for (final id in ids) {
        vector[id] = 1;
      }
      final r = await runtime.run(ModelTask.recordClassification, {
        'features': vector,
        'featureConfig': systemFeatureConfig,
      });
      if (r.mode != 'model') {
        return SystemProposal('unavailable', reason: r.reason, run: r);
      }
      final output = r.output!;
      if (output['modelId'] != systemPilotId ||
          output['modelSha256'] != info['modelSha256'] ||
          jsonEncode(output['labels']) != jsonEncode(labels) ||
          output['sourceStatus'] != 'authorship_unconfirmed' ||
          output['labelStatus'] != 'single_ai_draft_not_human_reviewed' ||
          output['use'] != 'suggestion_only') {
        throw const FormatException('output_mismatch');
      }
      final scores = (output['scores'] as List)
          .cast<num>()
          .map((v) => v.toDouble())
          .toList();
      if (scores.length != labels.length ||
          scores.any((v) => !v.isFinite || v < 0 || v > 1) ||
          (scores.fold<double>(0, (a, b) => a + b) - 1).abs() > .001) {
        throw const FormatException('scores_invalid');
      }
      final order = List.generate(labels.length, (i) => i)
        ..sort((a, b) {
          final c = scores[b].compareTo(scores[a]);
          return c != 0 ? c : labels[a].compareTo(labels[b]);
        });
      return SystemProposal(
        'suggestion_only',
        labels: [for (final i in order.take(3)) labels[i]],
        scores: [for (final i in order.take(3)) scores[i]],
        run: r,
      );
    } catch (_) {
      return const SystemProposal(
        'unavailable',
        reason: 'pilot_validation_failed',
      );
    }
  }
}
