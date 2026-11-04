import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_golden_comparator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('환경별 기준도 픽셀 하나가 바뀌면 실패하고 일반 비교로 갱신하지 않는다', () async {
    expect(goldenFileComparator, isA<HostGoldenComparator>());
    final directory = await Directory.systemTemp.createTemp('strict-golden-');
    addTearDown(() => directory.delete(recursive: true));
    final comparator = HostGoldenComparator(
      directory.uri.resolve('sample_test.dart'),
      hostAbi: 'macos_arm64',
    );
    Future<Uint8List> pixel(ui.Color color) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1, 1);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      picture.dispose();
      return bytes;
    }

    final key = comparator.getTestUri(Uri.parse('goldens/sample.png'), null);
    final black = await pixel(const ui.Color(0xff000000));
    final white = await pixel(const ui.Color(0xffffffff));
    await comparator.update(key, black);
    expect(await comparator.compare(black, key), isTrue);
    await expectLater(
      comparator.compare(white, key),
      throwsA(isA<FlutterError>()),
    );
    expect(await comparator.compare(black, key), isTrue);
  });
}
