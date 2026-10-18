import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/ui_util.dart';

void main() {
  test('media byte formatting uses the correct binary unit', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1 KB');
    expect(formatBytes(1024 * 1024), '1 MB');
    expect(formatBytes(116 * 1024 * 1024), '116 MB');
    expect(formatBytes(-1), '未知大小');
  });
}
