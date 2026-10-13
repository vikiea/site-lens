import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/metadata.dart';
import 'package:site_lens/scripts/script_service.dart';

const fixture = 'integration_test/fixtures/miss_player_5.6.17.user.js';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('imports and enables the supplied Miss Player userscript', (
    tester,
  ) async {
    final source = await rootBundle.loadString(fixture);
    final metadata = ScriptMetadata.parse(source);
    expect(metadata.canEnable, isTrue, reason: metadata.errors.join('\n'));
    expect(metadata.name, contains('Miss Player'));
    expect(metadata.version, '5.6.17');
    expect(metadata.matches, isNotEmpty);

    final db = AppDatabase(NativeDatabase.memory());
    final service = ScriptService(db, ControlledHttp());
    try {
      final script = await service.save(source);
      await service.enable(script, Cancellation());
      final saved = (await db.scripts()).single;
      expect(saved.id, script.id);
      expect(saved.enabled, isTrue);
      expect(saved.approvedDigest, isNotNull);
    } finally {
      await db.close();
    }
  });
}
