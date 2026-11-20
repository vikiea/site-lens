import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/web_page_origin.dart';
import 'app_controller.dart';
import 'navigation_observer.dart';
import 'screens.dart';
import 'ui_util.dart';

/// Label of the source-page command, in the glossary's wording.
///
/// One constant so the row menu, the persistent notice and the tests cannot
/// drift apart.
const mediaTaskSourcePageActionLabel = '打开来源页';

/// Opens the 来源页 (source page) a media task was observed on.
///
/// A retry can only recover authorization when the page hands the media over
/// again, so the page is the natural next stop. Two rules keep the entry from
/// turning into a general navigation hatch:
///
/// * the page must be the one the task records, and it may only be asked for
///   by an existing task — the recorded address is the reference, because a
///   task's play address is resolved by the page through several hops and
///   routinely lives on another site, so the media's host says nothing about
///   which page is the task's;
/// * the visit goes through the same tab path as every other entry, so an
///   already open tab for that page is reused and activated instead of a
///   duplicate appearing.
///
/// Returns `true` only when the browser is actually showing the page: a refusal
/// and an aborted tab lifecycle both return `false`, so no caller can report
/// success for a page nobody sees.
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
  if (!sourcePageBelongsToTask(task, page)) {
    if (context.mounted) _refuse(context, '该来源页不属于这个任务，已停止打开');
    return false;
  }
  if (!context.mounted) return false;
  var shown = false;
  await safely(context, () async {
    final tab = await app.openUrl(page, label: page.host);
    if (!app.browserTabs.contains(tab)) return;
    await app.activateTab(tab);
    if (!app.browserTabs.contains(tab) || !identical(app.activeBrowser, tab)) {
      return;
    }
    if (!context.mounted) return;
    shown = true;
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
  // The route is on screen until the user comes back; anything that unwound
  // before the push did not show the page.
  return shown && app.browserTabs.contains(app.activeBrowser);
}

/// Whether [page] is the page [task] records as its 来源页.
///
/// Exposed so the entry's gate can be exercised without a browser.
///
/// The recorded source page is the only reference: the media address is
/// resolved by the page itself and may sit on any host, so comparing the two
/// would refuse the normal case. A task without a recorded page has nothing to
/// vouch for [page] and is refused instead.
bool sourcePageBelongsToTask(MediaTask? task, Uri page) {
  if (task == null) return false;
  final recorded = webSourcePageUrl(task.sourceUrl);
  if (recorded == null) return false;
  return sameWebOrigin(recorded, page);
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
