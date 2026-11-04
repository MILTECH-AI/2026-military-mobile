import 'package:flutter_test/flutter_test.dart';
import 'package:military_maintenance/data/calendar.dart';

void main() {
  test('서머타임 시작·종료의 날짜 차이는 23·25시간과 무관하다', () {
    expect(calendarDaysBetween(DateTime(2026, 3, 9), DateTime(2026, 3, 8)), 1);
    expect(
      calendarDaysBetween(DateTime(2026, 11, 2), DateTime(2026, 11, 1)),
      1,
    );
    expect(calendarDaysBetween(DateTime(2026, 3, 12), DateTime(2026, 3, 5)), 7);
    expect(
      calendarDaysBetween(DateTime(2026, 3, 5), DateTime(2026, 3, 12)),
      -7,
    );
  });
}
