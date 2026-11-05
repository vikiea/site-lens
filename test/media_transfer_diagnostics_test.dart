import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_transfer_diagnostics.dart';

void main() {
  test('task error persists only allowlisted human diagnostics', () {
    final text = mediaTransferFailureText(
      PlatformException(
        code: 'media_transfer',
        message: '媒体连接失败，已保留缓存，可重试',
        details: {
          'resource': 'key',
          'phase': 'response_headers',
          'route': 'http_proxy',
          'reason': 'tls_handshake',
          'attemptsUsed': 5,
          'bytesWritten': 0,
          'url': 'https://example.com/key?auth_key=private',
          'Cookie': 'secret',
          'proxy': '127.0.0.1:1234',
        },
      ),
    );
    expect(text, contains('资源：密钥'));
    expect(text, contains('TLS 握手失败'));
    expect(text, contains('尝试：5 次'));
    expect(text, isNot(contains('private')));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('127.0.0.1')));
  });
}
