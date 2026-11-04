import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'calendar.dart';

class ClassificationLabel {
  const ClassificationLabel(this.label, this.confidence, this.coverage);
  final String? label;
  final double confidence, coverage;
}

class MaintenanceSuggestion {
  const MaintenanceSuggestion(this.system, this.type);
  final ClassificationLabel system, type;
}

class LocalModels {
  LocalModels(this.prediction, this.classification);
  final Map<String, dynamic> prediction, classification;
  String get version => prediction['version'] as String;
  double get threshold => (prediction['validationThreshold'] as num).toDouble();

  static Future<LocalModels> load() async => LocalModels(
    jsonDecode(await rootBundle.loadString('assets/models/prediction.json'))
        as Map<String, dynamic>,
    jsonDecode(await rootBundle.loadString('assets/models/classification.json'))
        as Map<String, dynamic>,
  );

  double predict(Map<String, num> features) {
    final names = prediction['featureNames'] as List<dynamic>;
    var score = (prediction['bias'] as num).toDouble();
    final clip = (prediction['standardizedClip'] as num).toDouble();
    for (var i = 0; i < names.length; i++) {
      final raw = features[names[i]];
      if (raw == null || !raw.isFinite) {
        throw ArgumentError('Missing model feature');
      }
      final normalized =
          ((raw - (prediction['mean'][i] as num)) /
                  (prediction['scale'][i] as num))
              .clamp(-clip, clip);
      score += normalized * (prediction['weights'][i] as num);
    }
    return 1 / (1 + math.exp(-score.clamp(-40.0, 40.0)));
  }

  MaintenanceSuggestion classify(String part, String description) {
    final runes = '$part $description'
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .runes
        .toList();
    final counts = <String, int>{};
    for (final size in [2, 3]) {
      for (var i = 0; i <= runes.length - size; i++) {
        final token = String.fromCharCodes(runes.sublist(i, i + size));
        counts[token] = (counts[token] ?? 0) + 1;
      }
    }
    ClassificationLabel head(String name) {
      final model = classification['heads'][name] as Map<String, dynamic>;
      final scores = (model['logPriors'] as List)
          .map((v) => (v as num).toDouble())
          .toList();
      final vocabulary = model['tokenLogProbabilities'] as Map<String, dynamic>;
      var known = 0;
      for (final entry in counts.entries) {
        final weights = vocabulary[entry.key] as List<dynamic>?;
        if (weights == null) continue;
        known += entry.value;
        for (var i = 0; i < scores.length; i++) {
          scores[i] += entry.value * (weights[i] as num);
        }
      }
      final maxScore = scores.reduce(math.max);
      final probabilities = scores.map((s) => math.exp(s - maxScore)).toList();
      final sum = probabilities.reduce((a, b) => a + b);
      var best = 0;
      for (var i = 1; i < scores.length; i++) {
        if (scores[i] > scores[best]) best = i;
      }
      final confidence = probabilities[best] / sum;
      final total = counts.values.fold<int>(0, (a, b) => a + b);
      final coverage = known / math.max(1, total);
      final accepted =
          known >= (classification['minimumKnownTokens'] as num) &&
          coverage >= (classification['minimumCoverage'] as num) &&
          confidence >= (classification['minimumConfidence'] as num);
      return ClassificationLabel(
        accepted ? model['classes'][best] as String : null,
        confidence,
        coverage,
      );
    }

    return MaintenanceSuggestion(head('system'), head('maintenanceType'));
  }
}

class PredictionAssessment {
  const PredictionAssessment(this.features, this.reason);
  final Map<String, num>? features;
  final String? reason;
}

PredictionAssessment assessPrediction({
  required Map<String, dynamic> vehicle,
  required List<Map<String, dynamic>> operations,
  required List<Map<String, dynamic>> maintenance,
  required DateTime asOf,
}) {
  try {
    final rows = operations
        .where((r) => r['vehicleId'] == vehicle['id'])
        .toList();
    if (rows.isEmpty) return const PredictionAssessment(null, '운용 기록이 없습니다.');
    for (final row in rows) {
      if (row['created'] is! String ||
          DateTime.tryParse(row['created']) == null) {
        return const PredictionAssessment(null, '운용 기록의 시각을 확인해 주세요.');
      }
      for (final key in ['distance', 'hours', 'fuel']) {
        final value = row[key];
        if (value is! num || !value.isFinite || value < 0) {
          return const PredictionAssessment(null, '운용 누적값을 확인해 주세요.');
        }
      }
    }
    final features = predictionFeatures(
      vehicle: vehicle,
      operations: operations,
      maintenance: maintenance,
      asOf: asOf,
    );
    if (features == null) {
      return const PredictionAssessment(
        null,
        '월별 증분을 계산할 기록이 부족하거나 주행 증가량이 없습니다.',
      );
    }
    if (features['monthlyHours']! <= 0 || features['monthlyFuelL']! <= 0) {
      return const PredictionAssessment(
        null,
        '주행 증가에 대응하는 시간·유류 증가량을 확인해 주세요.',
      );
    }
    if (features.values.any((v) => !v.isFinite)) {
      return const PredictionAssessment(null, '분석 입력값을 확인해 주세요.');
    }
    return PredictionAssessment(features, null);
  } on FormatException {
    return const PredictionAssessment(null, '기록 날짜 형식을 확인해 주세요.');
  } on TypeError {
    return const PredictionAssessment(null, '기록의 필수 항목을 확인해 주세요.');
  }
}

/// Snapshot features: latest recorded operational month, maintenance through asOf.
/// Live partial-month inputs are provisional; no absent sensor readings are invented.
Map<String, num>? predictionFeatures({
  required Map<String, dynamic> vehicle,
  required List<Map<String, dynamic>> operations,
  required List<Map<String, dynamic>> maintenance,
  required DateTime asOf,
}) {
  final cutoff = DateTime(asOf.year, asOf.month, asOf.day);
  final vehicleId = vehicle['id'];
  final eligible =
      operations
          .where(
            (o) =>
                o['vehicleId'] == vehicleId &&
                !DateTime.parse(o['created'] as String).isAfter(
                  DateTime(
                    cutoff.year,
                    cutoff.month,
                    cutoff.day + 1,
                  ).subtract(const Duration(microseconds: 1)),
                ),
          )
          .toList()
        ..sort((a, b) {
          final timeOrder = (a['created'] as String).compareTo(
            b['created'] as String,
          );
          if (timeOrder != 0) {
            return timeOrder;
          }
          return ((a['_localOrder'] as int?) ?? 0).compareTo(
            (b['_localOrder'] as int?) ?? 0,
          );
        });
  if (eligible.isEmpty) return null;
  final latest = eligible.last;
  final latestDate = DateTime.parse(latest['created'] as String);
  final monthStart = DateTime(latestDate.year, latestDate.month);
  final previous = eligible
      .where((o) => DateTime.parse(o['created'] as String).isBefore(monthStart))
      .toList();
  num? delta(String total, String monthly) {
    if (previous.isNotEmpty) {
      return (latest[total] as num) - (previous.last[total] as num);
    }
    return latest[monthly] as num?;
  }

  final distance = delta('distance', 'monthlyDistanceKm');
  final hours = delta('hours', 'monthlyHours');
  final fuel = delta('fuel', 'monthlyFuelL');
  if (distance == null ||
      hours == null ||
      fuel == null ||
      distance <= 0 ||
      hours < 0 ||
      fuel < 0) {
    return null;
  }
  final history = maintenance
      .where(
        (r) =>
            r['vehicleId'] == vehicleId &&
            !DateTime.parse(r['date'] as String).isAfter(cutoff),
      )
      .toList();
  final recent = history
      .where(
        (r) =>
            calendarDaysBetween(cutoff, DateTime.parse(r['date'] as String)) <
            90,
      )
      .toList();
  final dates = history.map((r) => DateTime.parse(r['date'] as String)).toList()
    ..sort();
  return {
    'releaseYear': vehicle['year'] as num,
    'ageYears': cutoff.year - (vehicle['year'] as int),
    'distanceKm': latest['distance'] as num,
    'operatingHours': latest['hours'] as num,
    'fuelL': latest['fuel'] as num,
    'monthlyDistanceKm': distance,
    'monthlyHours': hours,
    'monthlyFuelL': fuel,
    'litersPer100Km': double.parse((fuel / distance * 100).toStringAsFixed(3)),
    'hasMaintenanceHistory': history.isEmpty ? 0 : 1,
    'daysSinceMaintenance': dates.isEmpty
        ? -1
        : calendarDaysBetween(cutoff, dates.last),
    'maintenanceCount90Days': recent.length,
    'correctiveCount90Days': recent
        .where((r) => r['maintenanceType'] == '고장수리')
        .length,
    'maintenanceCost90DaysWon': recent.fold<num>(
      0,
      (sum, r) => sum + (r['cost'] as num),
    ),
  };
}
