import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/web_page_origin.dart';
import 'app_controller.dart';
import 'navigation_observer.dart';
import 'screens.dart';
import 'ui_util.dart';

/// Label of the source-page command, in the glossary's wording.
///
/// One constant so the row menu, the transient message action and the tests
/// cannot drift apart.
const mediaTaskSourcePageActionLabel = '打开来源页';

/// Opens the 来源页 (source page) a media task was observed on.
///
/// A retry can only recover authorization when the page hands the media over
/// again, so the page is the natural next stop. Two rules keep the entry from
/// turning into a general navigation hatch:
///
/// * the page must belong to the same site as the task's own page and media —
///   a stored address pointing elsewhere is refused outright;
/// * the visit goes through the same tab path as every other entry, so an
///   already open tab for that page is reused and activated instead of a
///   duplicate appearing.
///
/// Returns `true` when the browser is showing the page.
Future<bool> openMediaTaskSourcePage(
  BuildContext context,
  AppController app, {
  required String taskId,
  Uri? sourceUrl,
}) async {
  final task = app.mediaTasks.task(taskId);
  final page = sourceUrl ?? webSourcePageUrl(task?.sourceUrl);
  if (page == null) {
    _refuse(context, '该任务没有可打开的来源页');
    return false;
  }
  final reference = task?.sourceUrl ?? page;
  if (!sameWebOrigin(reference, page)) {
    _refuse(context, '来源页与任务所在站点不一致，已停止打开');
    return false;
  }
  if (!context.mounted) return false;
  await safely(context, () async {
    final tab = await app.openUrl(page, label: page.host);
    if (!app.browserTabs.contains(tab)) return;
    await app.activateTab(tab);
    if (!app.browserTabs.contains(tab) || !identical(app.activeBrowser, tab)) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: siteLensBrowserRouteName),
        // The screen compares the site by identity against the active tab, so
        // hand it the tab's own candidate: a fresh one would reload the page
        // instead of showing the one already loaded.
        builder: (_) => BrowserScreen(app: app, site: tab.site),
      ),
    );
  });
  return true;
}

void _refuse(BuildContext context, String message) {
  showShortToast(context, message);
}

/// The source page address a task can offer, or `null` when it has none.
///
/// Lives here so the row menu and the retry message agree on exactly one
/// notion of "has a source page".
Uri? mediaTaskSourcePage(MediaTask? task) =>
    task == null ? null : webSourcePageUrl(task.sourceUrl);
