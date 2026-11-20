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
/// * the page must belong to the same site as the task's own page, and both
///   must agree with the site the task itself is bound to — the bound media
///   candidate and the live host session are the references, so a request that
///   names someone else's page is refused outright;
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
  if (!await _sourcePageMatchesTask(app, taskId, task, page)) {
    if (context.mounted) _refuse(context, '来源页与任务所在站点不一致，已停止打开');
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

/// Whether [page] is the source site [taskId] is actually bound to.
///
/// The reference comes from the task's own bindings, never from the request:
/// the bound media candidate is the observation the task downloads, and the
/// live host session is the page currently loaded for it. Either one
/// disagreeing with [page] is a refusal; a task with neither reference has
/// nothing to compare against and cannot vouch for [page] either.
Future<bool> _sourcePageMatchesTask(
  AppController app,
  String taskId,
  MediaTask? task,
  Uri page,
) async {
  if (task == null) return false;
  final candidate = await app.db.mediaCandidate(task.candidateId);
  if (candidate == null) return false;
  // The bound candidate is the observation the task downloads, so its page and
  // its media are the reference pair the request has to match.
  if (!sameWebOrigin(page, webSourcePageUrl(candidate.sourceUrl))) return false;
  if (!sameWebOrigin(page, candidate.mediaUrl)) return false;
  final references = <Uri>[
    // The task's own stored page.
    ?webSourcePageUrl(task.sourceUrl),
    // The page currently loaded in the task's host, when it is still alive.
    ?_sessionUrl(app, task.hostId),
  ];
  // A task with no live host and no stored page has nothing beyond the
  // candidate to compare against, and the candidate already matched.
  if (references.isEmpty) return true;
  return references.any((reference) => sameWebOrigin(reference, page));
}

Uri? _sessionUrl(AppController app, int hostId) {
  final session = app.hosts.sessions[hostId];
  if (session == null || session.disposed) return null;
  return webSourcePageUrl(session.url);
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
