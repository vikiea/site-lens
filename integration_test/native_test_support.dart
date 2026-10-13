import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/web_host/web_host.g.dart';

const browserMoreTooltip = '更多浏览器操作';

/// The fixed toolbar's own tooltips. The visible glyphs carry no text, so the
/// tooltip is also the accessible name the tests look up.
const browserBackTooltip = '后退';
const browserForwardTooltip = '前进';
const browserReloadTooltip = '刷新';
const browserHomeTooltip = '回到首页（浏览器不退出）';
const browserTabsTooltip = '标签页（缩略图选择）';
const browserExitTooltip = '退出浏览器到首页（保留标签页）';
const browserScriptsTooltip = '脚本菜单与恢复';
const browserNewTabTooltip = '新建标签页';
const browserCloseTabTooltip = '关闭当前标签页';

Future<void> waitForBrowserActionOrMore(
  WidgetTester tester,
  String actionTooltip, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byTooltip(actionTooltip).evaluate().isNotEmpty ||
        find.byTooltip(browserMoreTooltip).evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for $actionTooltip or $browserMoreTooltip');
}

Future<void> tapBrowserAction(WidgetTester tester, String actionTooltip) async {
  final direct = find.byTooltip(actionTooltip);
  if (direct.evaluate().isNotEmpty) {
    await tester.tap(direct);
    return;
  }

  final more = find.byTooltip(browserMoreTooltip);
  expect(more, findsOneWidget);
  await tester.tap(more);
  await tester.pumpAndSettle();
  final menuItem = find.text(actionTooltip);
  expect(menuItem, findsOneWidget);
  await tester.tap(menuItem);
}

Future<bool> openBrowserMoreIfNeeded(
  WidgetTester tester,
  String directActionTooltip,
) async {
  if (find.byTooltip(directActionTooltip).evaluate().isNotEmpty) {
    return false;
  }
  final more = find.byTooltip(browserMoreTooltip);
  expect(more, findsOneWidget);
  await tester.tap(more);
  await tester.pumpAndSettle();
  return true;
}

/// An explicit test preflight. Production cold start constructs no probe WebView.
Future<void> reportCapabilitiesForTest(AppController app) async {
  final probe = await app.hosts.create(HostPurpose.verification);
  try {
    app.capabilities = probe.capabilities;
  } finally {
    await app.hosts.destroy(probe);
  }
}
