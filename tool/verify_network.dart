import 'dart:io';

import 'package:site_lens/network/transport.dart';

/// Smoke test through the host's normal system network stack.
Future<void> main(List<String> args) async {
  final uri = args.isEmpty
      ? Uri.parse('https://example.com/')
      : Uri.parse(args.first);
  final response = await ControlledHttp().fetch(
    uri,
    connect: {uri.host},
    document: uri,
    cancel: Cancellation(),
    maxBytes: 65536,
  );
  if (response.status != 200) {
    throw StateError('HTTP smoke failed: ${response.status}');
  }
  stdout.writeln(
    'System HTTPS PASS: ${response.status}, ${response.bytes.length} bytes',
  );
}
