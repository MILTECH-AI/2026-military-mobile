import 'store.dart';

class VisionDetection {
  const VisionDetection(this.classId, this.score, this.box);
  final int classId;
  final double score;
  final List<double> box;
  String get label => switch (classId) {
    1 => 'person',
    2 => 'bicycle',
    3 => 'car',
    4 => 'motorcycle',
    6 => 'bus',
    8 => 'truck',
    17 => 'cat',
    18 => 'dog',
    _ => 'COCO #$classId',
  };
  Map<String, Object?> toJson() => {
    'classId': classId,
    'score': score,
    'box': box,
  };
}

class VisionAnalysis {
  const VisionAnalysis(this.modelId, this.modelSha256, this.detections);
  final String modelId, modelSha256;
  final List<VisionDetection> detections;
  factory VisionAnalysis.parse(Map<String, Object?> output) {
    if (output['modelId'] != 'ssd-mobilenet-int8-public-v1' ||
        output['modelSha256'] !=
            '2b79e6a7fb1ec6a33f332b9b10d82d9de4b7b49dcd26b5946921bb356895c954') {
      throw const FormatException('vision_model_mismatch');
    }
    final rows = output['detections'] as List;
    if (rows.length > 100) throw const FormatException('too_many_detections');
    final detections = <VisionDetection>[];
    for (final raw in rows) {
      final d = raw as Map,
          cls = d['classId'] as int,
          score = (d['score'] as num).toDouble();
      final box = (d['box'] as List)
          .cast<num>()
          .map((v) => v.toDouble())
          .toList();
      if (cls < 1 ||
          cls > 90 ||
          !score.isFinite ||
          score < .5 ||
          score > 1 ||
          box.length != 4 ||
          box.any((v) => !v.isFinite || v < 0 || v > 1) ||
          box[0] > box[2] ||
          box[1] > box[3]) {
        throw const FormatException('invalid_detection');
      }
      detections.add(VisionDetection(cls, score, box));
    }
    return VisionAnalysis(
      output['modelId'] as String,
      output['modelSha256'] as String,
      detections,
    );
  }
  Map<String, dynamic> toJson() => {
    'modelId': modelId,
    'modelSha256': modelSha256,
    'detections': detections.map((d) => d.toJson()).toList(),
    'purpose': 'public_runtime_probe_not_rexton_part_detection',
  };
}

class ReviewedVisionLink {
  const ReviewedVisionLink(
    this.modelId,
    this.classId,
    this.conceptId,
    this.evidence,
  );
  final String modelId, conceptId, evidence;
  final int classId;
}

/// No reviewed COCO-to-maintenance-part links exist. Never infer "car -> oil filter".
const reviewedVisionLinks = <ReviewedVisionLink>[];
List<Map<String, dynamic>> visionConceptCandidates(
  VisionAnalysis result,
  KnowledgeData knowledge, {
  List<ReviewedVisionLink> links = reviewedVisionLinks,
}) {
  final ids = {
    for (final d in result.detections)
      for (final link in links)
        if (link.modelId == result.modelId &&
            link.classId == d.classId &&
            link.evidence.trim().isNotEmpty)
          link.conceptId,
  };
  return knowledge.concepts.where((c) => ids.contains(c['id'])).toList();
}
