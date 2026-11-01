import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/store.dart';
import 'package:military_maintenance/rag_utility_device_probe.dart';

void main() {
  const evidence = MaintenanceEvidence(
    id: 'TEST',
    model: '가상',
    part: '가상',
    symptoms: '',
    title: '',
    location: '',
    text: '',
    sourceRef: {'file': '가상.pdf', 'page': 2},
  );
  Map<String, Object?> question() => {
    'id': 'TEST-Q',
    'question': '가상 질문',
    'selectedUnitPolicy': 'unselected',
    'expectedBehavior': 'evidence_reference',
    'goldEvidence': [
      {'evidenceId': 'TEST', 'file': '가상.pdf', 'pdfPage': 2},
    ],
    'mustRankFirst': ['TEST'],
  };
  test('evaluation rejects incorrect original page and missing gold before inference', () {
    final q = question();
    validateUtilityQuestion(q, [evidence]);
    q['goldEvidence'] = [
      {'evidenceId': 'TEST', 'file': '가상.pdf', 'pdfPage': 3},
    ];
    expect(() => validateUtilityQuestion(q, [evidence]), throwsFormatException);
    q['goldEvidence'] = [];
    expect(() => validateUtilityQuestion(q, [evidence]), throwsFormatException);
    q['expectedBehavior'] = 'no_evidence';
    q['mustRankFirst'] = [];
    validateUtilityQuestion(q, [evidence]);
  });
}
