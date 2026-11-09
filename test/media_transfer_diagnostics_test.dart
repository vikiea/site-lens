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

  for (final (reason, label) in [
    ('tls_protocol', 'TLS 协议或加密套件被拒'),
    ('tls_reset', 'TLS 握手期间连接被重置'),
    ('tls_handshake', 'TLS 握手失败'),
  ]) {
    test('a TLS failure keeps the actionable reason: $reason', () {
      final text = mediaTransferFailureText(
        PlatformException(
          code: 'media_transfer',
          message: '媒体连接失败，已保留缓存，可重试',
          details: {
            'resource': 'key',
            'phase': 'connect',
            'route': 'system_proxy',
            'reason': reason,
            'attemptsUsed': 5,
            'bytesWritten': 0,
          },
        ),
      );
      expect(text, contains(label));
      // The transport never forwards provider text.
      expect(text, isNot(contains('SSLHandshakeException')));
      expect(text, isNot(contains('127.0.0.1')));
    });
  }
}
