import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/update/update_service.dart';

void main() {
  test('stable is the default and channel choice survives settings JSON', () {
    const defaults = AppSettings();
    expect(defaults.updateChannel, UpdateChannel.stable);

    final beta = defaults.patch({'updateChannel': 'beta'});
    expect(beta.updateChannel, UpdateChannel.beta);
    expect(AppSettings.decode(beta.encode()).updateChannel, UpdateChannel.beta);
  });

  test('old settings without a channel remain stable', () {
    final settings = AppSettings.decode(
      '{"version":2,"themeMode":"system","themePreset":"sunset_coral"}',
    );
    expect(settings.updateChannel, UpdateChannel.stable);
  });

  test('semantic versions order beta before the matching stable release', () {
    final beta = AppVersion.parse('v0.2.0-beta.1');
    final stable = AppVersion.parse('v0.2.0');
    expect(beta.compareTo(stable), lessThan(0));
    expect(AppVersion.parse('v0.2.0-beta.2').compareTo(beta), greaterThan(0));
  });
}
