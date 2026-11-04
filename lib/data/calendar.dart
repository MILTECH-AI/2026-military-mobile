/// Difference between written calendar dates, without daylight-saving hours.
int calendarDaysBetween(DateTime end, DateTime start) => DateTime.utc(
  end.year,
  end.month,
  end.day,
).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
