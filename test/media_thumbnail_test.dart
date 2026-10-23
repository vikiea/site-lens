import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/media_thumbnail.dart';

Future<MemoryImage> _testImage(WidgetTester tester, Size size) async {
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = const Color(0xff808080);
    canvas.drawRect(Offset.zero & size, paint);
    paint.color = const Color(0xffff0000);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width / 5, size.height), paint);
    paint.color = const Color(0xff00ff00);
    canvas.drawRect(
      Rect.fromLTWH(size.width * 4 / 5, 0, size.width / 5, size.height),
      paint,
    );
    paint.color = const Color(0xff0000ff);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height / 5), paint);
    paint.color = const Color(0xffffff00);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 4 / 5, size.width, size.height / 5),
      paint,
    );
    final picture = recorder.endRecording();
    final decoded = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final bytes = await decoded.toByteData(format: ui.ImageByteFormat.png);
    decoded.dispose();
    picture.dispose();
    final provider = MemoryImage(bytes!.buffer.asUint8List());
    final stream = provider.resolve(ImageConfiguration.empty);
    final loaded = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      info.dispose();
      loaded.complete();
    }, onError: loaded.completeError);
    stream.addListener(listener);
    await loaded.future;
    stream.removeListener(listener);
    return provider;
  }))!;
}

void main() {
  for (final (name, source, displayed) in [
    ('landscape', const Size(160, 90), const Size(68, 38.25)),
    ('portrait', const Size(90, 160), const Size(27, 48)),
    ('square', const Size(100, 100), const Size(48, 48)),
    ('panorama', const Size(400, 20), const Size(68, 3.4)),
    ('tall', const Size(20, 400), const Size(2.4, 48)),
  ]) {
    testWidgets('$name thumbnail preserves ratio and all four image edges', (
      tester,
    ) async {
      final image = await _testImage(tester, source);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: MediaThumbnail(image: image),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final slot = tester.getRect(find.byType(MediaThumbnail));
      final painted = tester.getRect(find.byType(RawImage));
      expect(slot.size, SiteLensMetrics.mediaThumbnailSize);
      expect(painted.width, closeTo(displayed.width, 0.001));
      expect(painted.height, closeTo(displayed.height, 0.001));
      expect(painted.size.aspectRatio, closeTo(source.aspectRatio, 0.001));
      expect(painted.center, slot.center);
      expect(slot.contains(painted.topLeft), isTrue);
      expect(painted.right, lessThanOrEqualTo(slot.right));
      expect(painted.bottom, lessThanOrEqualTo(slot.bottom));

      final (pixels, width) = (await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final rendered = await boundary.toImage(pixelRatio: 4);
        final bytes = await rendered.toByteData();
        final width = rendered.width;
        rendered.dispose();
        return (bytes!, width);
      }))!;
      List<int> pixel(double x, double y) {
        final px = ((painted.left - slot.left + painted.width * x) * 4).floor();
        final py = ((painted.top - slot.top + painted.height * y) * 4).floor();
        final offset = (py * width + px) * 4;
        return List.generate(4, (i) => pixels.getUint8(offset + i));
      }

      // These bands lie near each source edge: cover/crop or distortion loses
      // them even when the thumbnail's outer slot still has the expected size.
      expect(pixel(0.1, 0.5), [255, 0, 0, 255]);
      expect(pixel(0.9, 0.5), [0, 255, 0, 255]);
      expect(pixel(0.5, 0.1), [0, 0, 255, 255]);
      expect(pixel(0.5, 0.9), [255, 255, 0, 255]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing and failed thumbnails keep a stable placeholder slot', (
    tester,
  ) async {
    Widget content(ImageProvider? image) => MaterialApp(
      home: Center(
        child: MediaThumbnail(image: image, placeholder: Icons.downloading),
      ),
    );
    await tester.pumpWidget(content(null));
    expect(find.byIcon(Icons.downloading), findsOneWidget);
    final emptySize = tester.getSize(find.byType(MediaThumbnail));
    await tester.pumpWidget(content(MemoryImage(Uint8List.fromList([0]))));
    expect(find.byIcon(Icons.downloading), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(tester.getSize(find.byType(MediaThumbnail)), emptySize);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('narrow $brightness list keeps its action with large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final image = await _testImage(tester, const Size(90, 160));
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.mistPine, brightness),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: ListTile(
                leading: MediaThumbnail(image: image),
                title: const Text(
                  '较长的中文媒体名称',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: const Text('下载中 · 50%'),
                trailing: IconButton(
                  tooltip: '媒体操作',
                  onPressed: () => tapped = true,
                  icon: const Icon(Icons.more_vert),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('媒体操作'));
      expect(tapped, isTrue);
      expect(
        tester.getSize(find.byType(RawImage)).aspectRatio,
        closeTo(90 / 160, 0.001),
      );
    });
  }
}
