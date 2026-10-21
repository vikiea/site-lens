import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/filter/filter_service.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Dart and native change snapshots only after the next navigation succeeds',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final api = _FilterHostApi();
      final http = ControlledHttp();
      final hosts = NativeHosts(db, ScriptService(db, http), http, api: api);
      final first = const FilterCompiler()
          .compile('||first.example^', snapshotId: 'first')
          .engine;
      final second = const FilterCompiler()
          .compile('||second.example^', snapshotId: 'second')
          .engine;
      hosts.setFilterEngine(first);
      final session = await hosts.create(HostPurpose.browsing);
      try {
        expect(session.filterEngine, same(first));
        expect(api.rules.last, contains('first.example'));
        hosts.setFilterEngine(second);
        expect(session.filterEngine, same(first));
        expect(api.rules, hasLength(1));
        api.fail = true;
        await hosts.onEvent(
          HostEvent(
            hostId: session.id,
            generation: 1,
            kind: 'invalidated',
            url: 'https://example.com/',
            detail: '',
          ),
        );
        expect(session.filterEngine, same(first));
        await hosts.getScriptsForNavigation(
          session.id,
          1,
          'https://example.com/',
        );
        expect(session.filterEngine, same(first));
        expect(session.errorKind, 'filterSnapshotLoadFailed');
        api.fail = false;
        await hosts.prepareFilterForNavigation(
          session.id,
          2,
          'https://example.com/',
        );
        expect(session.filterEngine, same(second));
        expect(api.rules.last, contains('second.example'));
        expect(session.errorKind, isNull);
      } finally {
        await hosts.destroy(session);
        await db.close();
      }
    },
  );
}

class _FilterHostApi extends FakeWebHostApi {
  final rules = <String>[];
  bool fail = false;
  @override
  Future<void> applyFilter(
    int hostId,
    HostFilterContextDto context,
    FilterPolicyDto policy,
    FilterSnapshotDto snapshot,
  ) async {
    if (fail) {
      throw PlatformException(
        code: 'invalid_filter',
        message: 'checksum mismatch',
      );
    }
    rules.add(snapshot.rules);
  }
}
