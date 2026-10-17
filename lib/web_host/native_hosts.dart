import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/database.dart';
import '../settings/settings_repository.dart';
import '../domain/models.dart';
import '../network/transport.dart';
import '../scripts/metadata.dart';
import '../scripts/script_service.dart';
import '../media/media_service.dart';
import '../filter/filter_service.dart';
import 'web_host.g.dart';

class HostSession {
  HostSession(this.id, this.purpose, this.capabilities);
  final int id;
  final HostPurpose purpose;
  final HostCapabilities capabilities;
  int generation = 0;
  bool disposed = false;
  bool loaded = false;
  bool mediaWasVisible = false;
  bool fullscreen = false;
  int interactions = 0;
  String url = '';
  String title = '';
  String? errorKind;
  String? error;
  Cancellation cancellation = Cancellation();
  final menus = <String, ScriptMenu>{};
  final registered = <String, String>{};
  final mediaCandidates = <String, MediaCandidate>{};
  FilterEngine? filterEngine;
  FilterPolicy filterPolicy = const FilterPolicy();
  FilterSnapshot? filterSnapshot;
}

class ScriptMenu {
  const ScriptMenu(
    this.scriptId,
    this.id,
    this.label,
    this.generation,
    this.revision,
  );
  final String scriptId;
  final String id;
  final String label;
  final int generation;
  final String revision;
}

class NativeHosts extends WebHostEvents {
  NativeHosts(this.db, this.scripts, this.http, {WebHostApi? api})
    : api = api ?? WebHostApi() {
    WebHostEvents.setUp(this);
  }
  final AppDatabase db;
  final ScriptService scripts;
  final ControlledHttp http;
  final WebHostApi api;
  final sessions = <int, HostSession>{};
  FilterEngine? filterEngine;
  FilterPolicy filterPolicy = const FilterPolicy();
  FilterSnapshot? filterSnapshot;

  /// Policy [AppController] owns and pushes to every host: the app decides, the
  /// native host only enforces. New hosts get the current value at creation, and
  /// [applyPreferences] keeps live ones in step when a switch is flipped.
  HostPreferences preferences = HostPreferences(
    followEntryRedirects: true,
    pullToRefresh: false,
  );

  Future<void> applyPreferences(HostPreferences next) async {
    preferences = next;
    for (final session in sessions.values.toList()) {
      if (session.disposed) continue;
      await api.applyPreferences(session.id, next);
    }
  }

  void setFilterEngine(
    FilterEngine? next, {
    FilterPolicy policy = const FilterPolicy(),
    FilterSnapshot? snapshot,
  }) {
    filterEngine = next;
    filterPolicy = policy;
    filterSnapshot = snapshot;
    for (final session in sessions.values.toList()) {
      if (!session.disposed) unawaited(_applyFilter(session));
    }
  }

  Future<void> _applyFilter(HostSession session) async {
    if (session.disposed) return;
    final snapshot = filterSnapshot;
    final engine = filterEngine;
    final rules = engine == null
        ? const <Map<String, Object?>>[]
        : engine.rules
              .map(
                (rule) => <String, Object?>{
                  'pattern': rule.pattern,
                  'block': rule.block,
                  'cosmetic': rule.cosmetic,
                  'hostOnly': rule.hostOnly,
                  'domain': rule.domain,
                  'exception': rule.exception,
                  'scriptlet': rule.scriptlet,
                  'scriptletArgs': rule.scriptletArgs,
                },
              )
              .toList(growable: false);
    final source = session.url.isEmpty ? 'https://invalid.local/' : session.url;
    try {
      await api.applyFilter(
        session.id,
        HostFilterContextDto(
          hostId: session.id,
          generation: session.generation,
          sourceUrl: source,
          snapshotId: snapshot?.id ?? '',
        ),
        FilterPolicyDto(
          enabled: filterPolicy.enabled,
          pageFiltering: filterPolicy.pageFiltering,
          domainExceptions: filterPolicy.domainExceptions.toList(
            growable: false,
          ),
          blockedDomains: filterPolicy.blockedDomains.toList(growable: false),
        ),
        FilterSnapshotDto(
          id: snapshot?.id ?? '',
          version: snapshot?.version ?? '',
          sha256: snapshot?.sha256 ?? '',
          state: snapshot?.state.name ?? FilterSnapshotState.missing.name,
          rules: jsonEncode(rules),
        ),
      );
    } catch (error) {
      // Older/iOS hosts can lack a request interception channel. Keep Dart's
      // filtering authority active and expose the degraded capability instead
      // of allowing an unawaited platform exception to fail a later test/UI
      // operation.
      session.errorKind = 'filterUnavailable';
      session.error = error.toString();
    }
  }

  /// Called when the page asks for a new window (`window.open`,
  /// `target="_blank"`). The host stays put; the app decides whether to open a
  /// tab. Real popup windows are never created.
  void Function(int hostId, String url)? onNewWindow;
  void Function(HostSession session)? onInvalidated;
  final changed = ValueNotifier<int>(0);
  final _queues = <String, Future<void>>{};
  final _requests = <String, Cancellation>{};
  final _aborted = <String>{};
  int _nextId = 0;
  Future<HostSession> create(HostPurpose purpose) async {
    final id = ++_nextId;
    final capabilities = await api.create(id, purpose, preferences);
    final session = HostSession(id, purpose, capabilities);
    sessions[id] = session;
    if (purpose != HostPurpose.browsing && !capabilities.privateProbes) {
      await destroy(session);
      throw StateError('检测数据隔离不可用：${capabilities.reason}');
    }
    if (filterEngine != null ||
        filterPolicy.enabled ||
        filterSnapshot != null) {
      await _applyFilter(session);
    }
    return session;
  }

  Future<void> configure(HostSession session) async {
    final registrations = session.purpose == HostPurpose.browsing
        ? await scripts.registrations()
        : <ScriptRegistration>[];
    session.registered
      ..clear()
      ..addEntries(
        registrations
            .where((r) => !r.privileged || session.capabilities.isolatedScripts)
            .map((r) => MapEntry(r.id, r.revision)),
      );
    await api.registerScripts(session.id, registrations);
  }

  Future<void> navigate(HostSession session, Uri url) async {
    await api.navigate(session.id, url.toString());
  }

  List<MediaCandidate> mediaCandidates(HostSession session) =>
      List.unmodifiable(session.mediaCandidates.values);

  List<MediaCandidate> mediaCandidatesForHost(int hostId, {int? generation}) {
    final session = sessions[hostId];
    if (session == null || session.disposed) return const [];
    final expected = generation ?? session.generation;
    return List.unmodifiable(
      session.mediaCandidates.values.where(
        (candidate) => candidate.generation == expected,
      ),
    );
  }

  MediaCandidate authorizeMediaCandidate(int hostId, String candidateId) {
    final session = sessions[hostId];
    if (session == null || session.disposed) {
      throw StateError(MediaErrorCode.staleGeneration);
    }
    final candidate = session.mediaCandidates[candidateId];
    if (candidate == null) throw StateError(MediaErrorCode.invalidUrl);
    const validator = MediaCandidateValidator();
    validator.validate(
      candidate,
      hostId: hostId,
      generation: session.generation,
      sourceUrl: webUri(
        session.url.isEmpty ? candidate.sourceUrl.toString() : session.url,
      ),
    );
    if (session.filterEngine?.evaluate(
          candidate.mediaUrl,
          policy: session.filterPolicy,
        ) ==
        FilterDecision.block) {
      throw StateError('媒体地址被当前过滤快照阻止');
    }
    return candidate;
  }

  Future<void> destroy(HostSession session) async {
    if (session.disposed) return;
    session.disposed = true;
    session.cancellation.cancel();
    session.menus.clear();
    session.mediaCandidates.clear();
    _aborted.removeWhere((key) => key.startsWith('${session.id}:'));
    sessions.remove(session.id);
    await api.destroy(session.id);
  }

  Future<void> invokeMenu(HostSession session, ScriptMenu menu) async {
    if (session.disposed ||
        session.generation != menu.generation ||
        session.registered[menu.scriptId] != menu.revision) {
      throw const Cancelled();
    }
    await api.invokeMenu(
      session.id,
      menu.scriptId,
      menu.id,
      menu.generation,
      menu.revision,
    );
  }

  @override
  Future<void> onEvent(HostEvent event) async {
    final session = sessions[event.hostId];
    if (session == null ||
        session.disposed ||
        event.generation < session.generation) {
      return;
    }
    if (event.generation != session.generation) {
      _aborted.removeWhere((key) => key.startsWith('${session.id}:'));
      session.cancellation.cancel();
      session.cancellation = Cancellation();
      session.menus.clear();
      session.mediaCandidates.clear();
      session.generation = event.generation;
      session.filterEngine = filterEngine;
      session.filterPolicy = filterPolicy;
      session.filterSnapshot = filterSnapshot;
      session.loaded = false;
      session.error = null;
      session.errorKind = null;
    }
    session.url = event.url;
    if (event.kind == 'title') {
      session.title = event.detail.length <= 512
          ? event.detail
          : event.detail.substring(0, 512);
    }
    if (event.kind == 'fullscreen') {
      session.fullscreen = event.detail == 'entered';
    }
    if (event.kind == 'interaction') session.interactions++;
    if (event.kind == 'newWindow') {
      final target = event.detail.isEmpty ? event.url : event.detail;
      if (target.isNotEmpty) onNewWindow?.call(event.hostId, target);
    }
    if (event.kind == 'mediaCandidate' &&
        session.purpose == HostPurpose.browsing) {
      try {
        final raw = jsonDecode(event.detail) as Map<String, dynamic>;
        final source = webUri(session.url);
        final media = webUri(raw['url'] as String? ?? '');
        final candidate = MediaCandidate(
          id: 'dom:${session.id}:${session.generation}:${media.removeFragment()}',
          hostId: session.id,
          generation: session.generation,
          sourceUrl: source,
          mediaUrl: media.removeFragment(),
          title: (raw['title'] as String? ?? '').trim().substring(
            0,
            (raw['title'] as String? ?? '').length.clamp(0, 512),
          ),
          mime: (raw['mime'] as String? ?? '').trim().substring(
            0,
            (raw['mime'] as String? ?? '').length.clamp(0, 128),
          ),
          source: MediaCandidateSource.dom,
          durationMs: (raw['durationMs'] as num?)?.toInt(),
          createdAt: DateTime.now().toUtc(),
        );
        const MediaCandidateValidator().validate(
          candidate,
          hostId: session.id,
          generation: session.generation,
          sourceUrl: source,
        );
        if (session.filterEngine?.evaluate(
              candidate.mediaUrl,
              policy: session.filterPolicy,
            ) !=
            FilterDecision.block) {
          session.mediaCandidates[candidate.id] = candidate;
          unawaited(db.saveMediaCandidate(candidate));
          changed.value++;
        }
      } catch (_) {
        // Media telemetry is untrusted page data; malformed candidates are
        // ignored and never become persisted tasks.
      }
    }
    if (event.kind == 'hostInvalidated') {
      session.errorKind = event.kind;
      session.error = event.detail;
      session.disposed = true;
      session.cancellation.cancel();
      session.menus.clear();
      session.registered.clear();
      sessions.remove(session.id);
      onInvalidated?.call(session);
      await api.destroy(session.id);
    }
    if (event.kind == 'loaded') session.loaded = true;
    if (event.kind == 'started') session.loaded = false;
    if ([
      'certificateError',
      'networkError',
      'httpError',
      'scriptsSuspended',
    ].contains(event.kind)) {
      session.errorKind = event.kind;
      session.error = event.detail;
    }
    changed.value++;
  }

  @override
  Future<List<ScriptRegistration>> getScriptsForNavigation(
    int hostId,
    int generation,
    String url,
  ) async {
    final session = sessions[hostId];
    if (session == null ||
        session.disposed ||
        generation < session.generation) {
      throw const Cancelled();
    }
    _aborted.removeWhere((key) => key.startsWith('$hostId:'));
    session.cancellation.cancel();
    session.cancellation = Cancellation();
    session.generation = generation;
    session.menus.clear();
    // Bind the immutable snapshot to this document. A later refresh takes
    // effect on the next navigation and never changes an active page's rules.
    session.filterEngine = filterEngine;
    session.filterPolicy = filterPolicy;
    session.filterSnapshot = filterSnapshot;
    if (session.purpose != HostPurpose.browsing) {
      await NetworkPolicy.publicNavigation(webUri(url));
      return [];
    }
    await Future.wait(
      _queues.entries
          .where((e) => e.key.startsWith('$hostId:'))
          .map((e) => e.value),
    );
    if (session.disposed || session.generation != generation) {
      throw const Cancelled();
    }
    final registrations = await scripts.registrations();
    if (session.disposed || session.generation != generation) {
      throw const Cancelled();
    }
    session.registered
      ..clear()
      ..addEntries(
        registrations
            .where((r) => !r.privileged || session.capabilities.isolatedScripts)
            .map((r) => MapEntry(r.id, r.revision)),
      );
    return registrations;
  }

  bool _active(HostSession session, GmRequest r) =>
      !session.disposed &&
      session.generation == r.generation &&
      session.purpose == HostPurpose.browsing &&
      session.registered[r.scriptId] == r.revision;
  @override
  Future<String> onGmRequest(GmRequest request) async {
    Map<String, dynamic>? payload;
    try {
      if (request.payload.length > 128 * 1024) throw StateError('桥接消息过大');
      payload = jsonDecode(request.payload) as Map<String, dynamic>;
      final session = sessions[request.hostId];
      if (session == null || !_active(session, request)) {
        throw const Cancelled();
      }
      final script = (await db.scripts())
          .where((s) => s.id == request.scriptId)
          .firstOrNull;
      if (script == null ||
          !script.enabled ||
          script.approvedDigest != request.revision ||
          (await SettingsRepository(db).read()).scriptsDisabled) {
        throw StateError('脚本已关闭或确认失效');
      }
      final metadata = ScriptMetadata.parse(script.source);
      if (metadata.pageWorld ||
          !metadata.canEnable ||
          !metadata.matchesUrl(webUri(request.documentUrl))) {
        throw StateError('脚本来源/环境不符');
      }
      final op = payload['op'] as String;
      final args = payload['args'] as Map<String, dynamic>;
      const permissions = {
        'getValue': ['GM_getValue', 'GM.getValue'],
        'setValue': ['GM_setValue', 'GM.setValue'],
        'deleteValue': ['GM_deleteValue', 'GM.deleteValue'],
        'listValues': ['GM_listValues', 'GM.listValues'],
        'registerMenu': ['GM_registerMenuCommand', 'GM.registerMenuCommand'],
        'unregisterMenu': [
          'GM_unregisterMenuCommand',
          'GM.unregisterMenuCommand',
        ],
        'xhr': ['GM_xmlhttpRequest', 'GM.xmlHttpRequest'],
        'xhrAbort': ['GM_xmlhttpRequest', 'GM.xmlHttpRequest'],
        'setClipboard': ['GM_setClipboard', 'GM.setClipboard'],
        'notify': ['GM_notification', 'GM.notification'],
        'openExternal': ['GM_openInTab', 'GM.openInTab'],
        'registerMedia': ['SiteLens.registerMedia'],
      };
      if (op != 'error' &&
          !(permissions[op]?.any(metadata.grants.contains) ?? false)) {
        throw StateError('未声明的 GM 操作：$op');
      }
      Future<void> ensureActive({bool inspectDocument = true}) async {
        if (!_active(session, request)) throw const Cancelled();
        // Menu registration is a document-local bookkeeping operation. The
        // WebView can be between committed frames while a document-end script
        // registers its menu, so forcing an HTML inspection here turns a valid
        // bridge request into a timing race. NativeWebHost still checks the
        // binding, generation, source origin, and current URL before replying.
        if (!inspectDocument) return;
        final snapshot = await api
            .inspect(session.id, 'html')
            .timeout(const Duration(seconds: 2));
        if (!_active(session, request) ||
            snapshot.generation != request.generation ||
            webUri(snapshot.url).origin != webUri(request.documentUrl).origin) {
          throw const Cancelled();
        }
      }

      final skipDocumentInspection =
          op == 'registerMenu' || op == 'unregisterMenu';
      await ensureActive(inspectDocument: !skipDocumentInspection);
      Object? value;
      if (op == 'setClipboard') {
        await Clipboard.setData(
          ClipboardData(text: args['text'] as String? ?? ''),
        );
        value = true;
      } else if (op == 'notify') {
        await api.notify(
          session.id,
          args['title'] as String? ?? 'Site Lens',
          args['body'] as String? ?? '',
        );
        value = true;
      } else if (op == 'openExternal') {
        await api.openExternal(session.id, args['url'] as String? ?? '');
        value = true;
      } else if (op == 'xhr') {
        final key =
            '${session.id}:${request.generation}:${request.scriptId}:${args['requestId']}';
        if (_requests.length >= 8) throw StateError('同时 GM 网络请求最多 8 个');
        final cancel = Cancellation();
        final target = webUri(args['url'] as String);
        if (session.filterEngine?.evaluate(
              target,
              policy: session.filterPolicy,
            ) ==
            FilterDecision.block) {
          throw StateError('请求被过滤规则阻止');
        }
        if (_aborted.remove(key)) cancel.cancel();
        session.cancellation.onCancel(cancel.cancel);
        _requests[key] = cancel;
        try {
          final response = await http.fetch(
            target,
            connect: script.networkMode == ScriptNetworkMode.public
                ? const {'*'}
                : metadata.connect,
            document: webUri(request.documentUrl),
            cancel: cancel,
            method: args['method'] as String? ?? 'GET',
            headers: (args['headers'] as Map<String, dynamic>? ?? {}).map(
              (k, v) => MapEntry(k, v.toString()),
            ),
            body: args['data'] as String?,
            timeout: Duration(
              milliseconds: (args['timeout'] as num? ?? 15000).toInt().clamp(
                1,
                30000,
              ),
            ),
          );
          value = {
            'status': response.status,
            'statusText': '',
            'responseText': utf8.decode(response.bytes, allowMalformed: true),
            'responseHeaders': response.headers.entries
                .map((e) => '${e.key}: ${e.value}')
                .join('\r\n'),
            'finalUrl': response.url.toString(),
          };
        } finally {
          _requests.remove(key);
        }
      } else if (op == 'registerMedia') {
        if (!metadata.grants.contains('SiteLens.registerMedia')) {
          throw StateError('未声明 SiteLens.registerMedia 权限');
        }
        final sourceUrl = webUri(request.documentUrl);
        final mediaUrl = webUri(args['url'] as String? ?? '');
        final title = args['title'] as String? ?? '';
        final mime = args['mime'] as String? ?? '';
        final candidate = MediaCandidate(
          id:
              args['candidateId'] as String? ??
              '${request.scriptId}:${request.generation}:$mediaUrl',
          hostId: request.hostId,
          generation: request.generation,
          sourceUrl: sourceUrl,
          mediaUrl: mediaUrl,
          title: title.substring(0, title.length.clamp(0, 512)),
          mime: mime.substring(0, mime.length.clamp(0, 128)),
          source: MediaCandidateSource.registered,
          durationMs: (args['durationMs'] as num?)?.toInt(),
          createdAt: DateTime.now().toUtc(),
        );
        const validator = MediaCandidateValidator();
        validator.validate(
          candidate,
          hostId: request.hostId,
          generation: request.generation,
          sourceUrl: sourceUrl,
        );
        if (session.filterEngine?.evaluate(
              mediaUrl,
              policy: session.filterPolicy,
            ) ==
            FilterDecision.block) {
          throw StateError('媒体地址被当前过滤快照阻止');
        }
        session.mediaCandidates[candidate.id] = candidate;
        await db.saveMediaCandidate(candidate);
        changed.value++;
        value = candidate.toJson();
      } else if (op == 'xhrAbort') {
        final key =
            '${session.id}:${request.generation}:${request.scriptId}:${args['requestId']}';
        if (_requests.containsKey(key)) {
          _requests[key]!.cancel();
        } else {
          if (_aborted.length >= 128) throw StateError('待取消请求过多');
          _aborted.add(key);
        }
      } else {
        final key = '${request.hostId}:${request.scriptId}';
        final previous = _queues[key] ?? Future<void>.value();
        final operation = previous.then((_) async {
          await ensureActive(inspectDocument: !skipDocumentInspection);
          switch (op) {
            case 'getValue':
              value =
                  (await db.values(script.id))[args['key'] as String] ??
                  args['fallback'];
            case 'listValues':
              value = (await db.values(script.id)).keys.toList();
            case 'setValue':
              await db.setValue(
                script.id,
                args['key'] as String,
                args['value'],
              );
            case 'deleteValue':
              await db.deleteValue(script.id, args['key'] as String);
            case 'registerMenu':
              if (session.menus.length >= 50) throw StateError('菜单数量超过限制');
              final menu = ScriptMenu(
                script.id,
                args['menuId'] as String,
                (args['label'] as String).substring(
                  0,
                  (args['label'] as String).length.clamp(0, 120),
                ),
                request.generation,
                request.revision,
              );
              session.menus['${script.id}:${menu.id}'] = menu;
              changed.value++;
            case 'unregisterMenu':
              session.menus.remove('${script.id}:${args['menuId']}');
              changed.value++;
            case 'error':
              await db.logScriptError(script.id, args['message'] as String);
            default:
              throw StateError('不支持的 GM 操作');
          }
        });
        _queues[key] = operation.catchError((Object _) {});
        await operation;
      }
      await ensureActive(inspectDocument: !skipDocumentInspection);
      return jsonEncode({'id': payload['id'], 'ok': true, 'value': value});
    } catch (e) {
      return jsonEncode({
        'id': payload?['id'],
        'ok': false,
        'error': e is Cancelled ? 'Document or host invalidated' : e.toString(),
      });
    }
  }
}
