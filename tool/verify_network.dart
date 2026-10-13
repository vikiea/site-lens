import 'package:site_lens/network/transport.dart';

import 'dart:io';

// Smoke-only resolver override, never used by the app. Useful with system Fake-IP DNS.

Future<void> main(List<String> args) async {
  final uri = Uri.parse('https://example.com/');
  final http = args.isEmpty
      ? ControlledHttp()
      : ControlledHttp(
          resolve: (_) async => args.map(InternetAddress.new).toList(),
        );
  final response = await http.fetch(
    uri,
    connect: {'example.com'},
    document: uri,
    cancel: Cancellation(),
    maxBytes: 65536,
  );
  if (response.status != 200 ||
      !String.fromCharCodes(response.bytes).contains('Example Domain')) {
    throw StateError('HTTPS smoke failed');
  }
  stdout.writeln(
    'HTTPS via pinned IP + verified TLS PASS: ${response.status}, ${response.bytes.length} bytes',
  );
}
