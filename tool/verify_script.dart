// Checks a real `.user.js` against this app's metadata contract before import.
//
//   dart run tool/verify_script.dart path/to/script.user.js
//
// Exits non-zero when the app would refuse to enable the script, so a real
// script can be triaged without hand-copying its metadata.
import 'dart:io';

import 'package:site_lens/scripts/metadata.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/verify_script.dart <file.user.js>');
    exit(64);
  }
  final file = File(args.single);
  if (!file.existsSync()) {
    stderr.writeln('No such file: ${args.single}');
    exit(66);
  }
  final source = file.readAsStringSync();
  final meta = ScriptMetadata.parse(source);
  stdout
    ..writeln('name: ${meta.name}')
    ..writeln('version: ${meta.version}')
    ..writeln('bytes: ${source.length}')
    ..writeln('runAt: ${meta.runAt}')
    ..writeln(
      'environment: ${meta.pageWorld ? 'page world (no native GM)' : 'isolated world'}',
    )
    ..writeln('matches: ${meta.matches.map((m) => m.pattern).join(', ')}')
    ..writeln('excludes: ${meta.excludes.map((m) => m.pattern).join(', ')}')
    ..writeln('grants: ${meta.grants.join(', ')}')
    ..writeln('connect: ${meta.connect.join(', ')}')
    ..writeln('requires: ${meta.requires.map((u) => u.toString()).join(', ')}');
  if (meta.errors.isEmpty) {
    stdout.writeln('VERDICT: canEnable=true');
    return;
  }
  stdout.writeln('VERDICT: canEnable=false');
  for (final error in meta.errors) {
    stdout.writeln('  error: $error');
  }
  exit(1);
}
