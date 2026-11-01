import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/flow_trace.dart';

void main() {
  test('전체 시각에서 사용자 대기만 분리하고 모델 전환 시간은 유지한다', () {
    final r = summarizeFlowTiming(1200, [
      {'name': 'load', 'durationMs': 100, 'userWait': false},
      {'name': 'confirm', 'durationMs': 900, 'userWait': true},
      {'name': 'save', 'durationMs': 150, 'userWait': false},
    ]);
    expect(r['wallTotalMs'], 1200);
    expect(r['userConfirmationWaitMs'], 900);
    expect(r['excludingUserWaitMs'], 300);
    expect(r['unstagedOverheadMs'], 50);
  });
}
