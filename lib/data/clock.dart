import 'package:flutter_riverpod/flutter_riverpod.dart';

/// UI date source; tests override this so rendered reference images stay stable.
final currentTimeProvider = Provider<DateTime>((ref) => DateTime.now());
