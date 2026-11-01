import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/flow_trace.dart';

void main() {
  test('측정이 끝난 뒤 정리 작업을 전체 흐름 시간에 추가하지 않는다', () async {
    final trace = FlowTrace();
    var called = false;
    await trace.model('fixture', 'reset', () async {
      called = true;
    });
    expect(called, isTrue);
    expect(trace.modelEvents, isEmpty);
  });
}
