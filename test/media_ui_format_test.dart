import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/ui_util.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';

void main() {
  test('media byte formatting uses the correct binary unit', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1 KB');
    expect(formatBytes(1024 * 1024), '1 MB');
    expect(formatBytes(116 * 1024 * 1024), '116 MB');
    expect(formatBytes(-1), '未知大小');
  });

  test('media duration formatting uses readable elapsed time', () {
    expect(formatMediaDuration(0), '--:--');
    expect(formatMediaDuration(65_000), '01:05');
    expect(formatMediaDuration(3_661_000), '1:01:01');
  });

  test('horizontal player gesture maps the full viewport to the duration', () {
    expect(
      mediaGestureSeekTarget(
        positionMs: 30_000,
        durationMs: 120_000,
        deltaPx: 100,
        viewportWidth: 400,
      ),
      60_000,
    );
    expect(
      mediaGestureSeekTarget(
        positionMs: 30_000,
        durationMs: 120_000,
        deltaPx: -400,
        viewportWidth: 400,
      ),
      0,
    );
  });
}
