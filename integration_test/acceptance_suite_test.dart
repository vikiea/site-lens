import 'package:integration_test/integration_test.dart';

import 'host_contract_test.dart' as host_contract;
import 'app_flow_test.dart' as app_flow;
import 'navigation_lease_test.dart' as navigation_lease;
import 'browser_tabs_test.dart' as browser_tabs;
import 'entry_fallback_test.dart' as entry_fallback;
import 'recon_test.dart' as recon;
import 'health_check_test.dart' as health_check;
import 'evidence_test.dart' as evidence;
import 'modernization_test.dart' as modernization;
import 'update_flow_test.dart' as update_flow;
import 'media_tasks_test.dart' as media_tasks;

/// One install, one run: registers every integration suite in this process.
///
/// `tool/run_android_acceptance.py --single-suite` uses this entrypoint to
/// avoid reinstalling the debug APK once per test file over wireless adb.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  host_contract.main();
  app_flow.main();
  navigation_lease.main();
  browser_tabs.main();
  entry_fallback.main();
  recon.main();
  health_check.main();
  evidence.main();
  modernization.main();
  update_flow.main();
  media_tasks.main();
}
