import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../domain/models.dart';
import '../network/transport.dart';
import '../web_host/native_hosts.dart';
import '../web_host/web_host.g.dart';

/// Time and grace budgets for one homepage verification. The bound is chosen
/// by network class; `loadedGrace` is how long a page that has already fired
/// onPageFinished is still given to hydrate before we give up early.
class ProbeTiming {
  const ProbeTiming({
    this.wifi = const Duration(seconds: 6),
    this.cellular = const Duration(seconds: 8),
    this.loadedGrace = const Duration(seconds: 3),
  });
  final Duration wifi;
  final Duration cellular;
  final Duration loadedGrace;
  Duration boundFor(NetworkClass network) =>
      network == NetworkClass.cellular ? cellular : wifi;
}

abstract interface class HomepageVerifier {
  Future<ProbeResult> verify(
    Candidate candidate,
    int round,
    Cancellation cancel,
  );
}

class NativeHomepageVerifier implements HomepageVerifier {
  NativeHomepageVerifier(
    this.hosts, {
    this.timing = const ProbeTiming(),
    Future<NetworkClass> Function()? networkClass,
  }) : _networkClass = networkClass ?? detectNetworkClass;
  final NativeHosts hosts;
  final ProbeTiming timing;
  final Future<NetworkClass> Function() _networkClass;
  @override
  Future<ProbeResult> verify(
    Candidate candidate,
    int round,
    Cancellation cancel,
  ) async {
    final watch = Stopwatch();
    HostSession? host;
    Uri? finalUrl;
    ProbeResult result(ProbeStatus status, [String? reason]) => ProbeResult(
      round: round,
      candidateId: candidate.id,
      stage: ProbeStage.homepage,
      status: status,
      entryUrl: candidate.url,
      finalUrl: finalUrl,
      elapsed: watch.elapsed,
      checkedAt: DateTime.now(),
      reason: reason,
    );
    final bound = timing.boundFor(await _networkClass());
    try {
      cancel.check();
      host = await hosts.create(HostPurpose.verification);
      cancel.check();
      final active = host;
      cancel.onCancel(() {
        unawaited(hosts.destroy(active));
      });
      watch.start();
      // Bound the navigation hand-off too, so a hung native call cannot blow
      // past the 6/8-second candidate budget.
      await hosts.navigate(host, candidate.url).timeout(bound - watch.elapsed);
      Duration? loadedAt;
      while (watch.elapsed < bound) {
        cancel.check();
        if (host.errorKind == 'certificateError') {
          return result(ProbeStatus.certificateError, host.error);
        }
        if (host.errorKind == 'networkError') {
          return result(ProbeStatus.offline, host.error);
        }
        if (host.errorKind == 'httpError') {
          return result(ProbeStatus.unavailable, host.error);
        }
        // Never let a single inspect push us past the candidate bound.
        final remaining = bound - watch.elapsed;
        // Never wait longer than what is left of the candidate bound.
        final inspectBudget = Duration(
          milliseconds: remaining.inMilliseconds.clamp(1, 2000),
        );
        final snapshot = await hosts.api
            .inspect(host.id, candidate.readySelector)
            .timeout(inspectBudget);
        if (watch.elapsed >= bound) {
          return result(
            host.loaded ? ProbeStatus.unavailable : ProbeStatus.timeout,
            '首页核心 DOM 未在 ${bound.inSeconds} 秒内就绪 (${candidate.readySelector})',
          );
        }
        if (snapshot.url.startsWith('http')) finalUrl = webUri(snapshot.url);
        if (snapshot.error.isNotEmpty) {
          return result(ProbeStatus.unavailable, snapshot.error);
        }
        if (snapshot.challenge) {
          return result(ProbeStatus.challenge, '检测到验证码/人机验证，请手动查看');
        }
        if (snapshot.interactionRequired) {
          return result(ProbeStatus.interactionRequired, '需要登录或页面交互');
        }
        if (snapshot.ready && finalUrl != null) {
          cancel.check();
          return result(
            ProbeStatus.ready,
            '核心 DOM 就绪 (${candidate.readySelector})',
          );
        }
        // Early exit: only when the page has finished loading AND the ready
        // selector still yields no text at all (`text` is the selector root's
        // textContent, so it is empty when the selector has not matched yet).
        // A root that already has text but is not "ready" yet keeps the full
        // 6/8s budget, so a slow-but-valid render is never rejected early.
        if (host.loaded && snapshot.text.isEmpty) {
          loadedAt ??= watch.elapsed;
          if (watch.elapsed - loadedAt >= timing.loadedGrace) {
            return result(
              ProbeStatus.unavailable,
              '页面已加载但核心 DOM 为空，提前判不可用 (${candidate.readySelector})',
            );
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return result(
        host.loaded ? ProbeStatus.unavailable : ProbeStatus.timeout,
        '首页核心 DOM 未在 ${bound.inSeconds} 秒内就绪 (${candidate.readySelector})',
      );
    } on TimeoutException {
      return result(
        cancel.cancelled ? ProbeStatus.cancelled : ProbeStatus.timeout,
        '网页执行或 DOM 检查超时',
      );
    } on Cancelled {
      return result(ProbeStatus.cancelled);
    } catch (e) {
      return result(
        cancel.cancelled ? ProbeStatus.cancelled : ProbeStatus.unsupported,
        e.toString(),
      );
    } finally {
      if (host != null) await hosts.destroy(host);
    }
  }
}

class ProbeCoordinator extends ChangeNotifier {
  ProbeCoordinator({
    required this.candidates,
    required this.httpProbe,
    required this.verifier,
    required this.save,
  });
  final Future<List<Candidate>> Function() candidates;
  final HttpProbe httpProbe;
  final HomepageVerifier verifier;
  final Future<void> Function(ProbeResult) save;
  Cancellation _cancel = Cancellation();
  int round = 0;
  bool running = false;
  bool fullCoverage = false;
  String? notice;
  final results = <int, ProbeResult>{};
  List<ProbeResult> get recommendations {
    final unique = <String, ProbeResult>{};
    for (final r in results.values.where(
      (r) => r.round == round && r.verified && r.finalUrl != null,
    )) {
      final key = landingKey(r.finalUrl!);
      if (!unique.containsKey(key) || r.elapsed! < unique[key]!.elapsed!) {
        unique[key] = r;
      }
    }
    return unique.values.toList()..sort(compareProbeResults);
  }

  void cancel([String reason = '检测已取消，旧结果不再参与推荐']) {
    _cancel.cancel();
    round = DateTime.now().microsecondsSinceEpoch > round
        ? DateTime.now().microsecondsSinceEpoch
        : round + 1;
    running = false;
    notice = reason;
    notifyListeners();
  }

  Future<void> run({bool all = false, int? profileId}) async {
    cancel('开始新一轮检测');
    final token = _cancel = Cancellation();
    final id = round;
    results.clear();
    running = true;
    fullCoverage = all;
    notice = null;
    notifyListeners();
    final pendingSaves = <Future<void>>[];
    String? persistenceError;
    void publish(ProbeResult result) {
      if (token.cancelled || round != id) return;
      results[result.candidateId] = result;
      pendingSaves.add(
        save(result).catchError((Object e) {
          persistenceError = e.toString();
        }),
      );
      notifyListeners();
    }

    try {
      final sites = (await candidates())
          .where(
            (c) => c.enabled && (profileId == null || c.profileId == profileId),
          )
          .toList();
      var next = 0;
      Future<void> worker() async {
        while (!token.cancelled && next < sites.length) {
          final site = sites[next++];
          publish(await httpProbe.run(site, id, token));
        }
      }

      await Future.wait(
        List.generate(sites.length.clamp(0, 4), (_) => worker()),
      );
      token.check();
      final reachable =
          results.values
              .where((r) => all || r.status == ProbeStatus.reachable)
              .toList()
            ..sort(compareProbeResults);
      // Coalesced entrypoints share a landing and aren't counted as independent coverage.
      final selected = <ProbeResult>[];
      final seen = <String>{};
      for (final r in reachable) {
        if (seen.add(landingKey(r.finalUrl ?? r.entryUrl))) selected.add(r);
      }
      final toVerify = all ? selected : selected.take(3).toList();
      if (all) {
        // Full-coverage round runs the DOM checks with a hard concurrency of 3.
        var next = 0;
        Future<void> worker() async {
          while (!token.cancelled && next < toVerify.length) {
            final preliminary = toVerify[next++];
            token.check();
            final site = sites.firstWhere(
              (c) => c.id == preliminary.candidateId,
            );
            publish(await verifier.verify(site, id, token));
          }
        }

        await Future.wait(
          List.generate(toVerify.length.clamp(0, 3), (_) => worker()),
        );
      } else {
        // Default round stays serial so the three numbers are directly
        // comparable: parallel checks would contend for bandwidth.
        for (final preliminary in toVerify) {
          token.check();
          final site = sites.firstWhere((c) => c.id == preliminary.candidateId);
          publish(await verifier.verify(site, id, token));
        }
      }
      await Future.wait(pendingSaves);
      token.check();
      notice =
          '首页已就绪 ${recommendations.length} 个不同落点；${all ? '全部已启用候选落点' : '仅初筛前三个不同落点'}。HTTP 可达不代表首页可用。${persistenceError == null ? '' : ' 记录保存失败：$persistenceError'}';
    } on Cancelled {
      /* Cancellation owns the replacement state. */
    } catch (e) {
      if (!token.cancelled) notice = e.toString();
    } finally {
      if (round == id && !token.cancelled) {
        running = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }
}

class PublishingDiscovery {
  PublishingDiscovery(this.db, this.hosts);
  final AppDatabase db;
  final NativeHosts hosts;
  Future<int> refresh(Cancellation cancel, {int? profileId}) async {
    final configured = await db.profilePages(profileId: profileId);
    final enabledProfileIds = (await db.profiles())
        .where((profile) => profile.enabled)
        .map((profile) => profile.id)
        .toSet();
    final pages = configured
        .where(
          (page) => page.enabled && enabledProfileIds.contains(page.profileId),
        )
        .toList();
    // Deny *every* configured publishing host, even when only one profile is
    // being rescanned, so a page cannot import another profile's own source.
    final configuredPages = await db.profilePages();
    final publishingHosts = configuredPages.map((p) => p.url.host).toSet();
    final publishingPageKeys = configuredPages
        .map((p) => webPageKey(p.url))
        .toSet();
    var added = 0;
    for (final page in pages) {
      HostSession? host;
      try {
        cancel.check();
        host = await hosts.create(HostPurpose.discovery);
        cancel.check();
        final active = host;
        cancel.onCancel(() {
          unawaited(hosts.destroy(active));
        });
        await hosts.navigate(host, page.url);
        final watch = Stopwatch()..start();
        List<Uri>? extracted;
        while (watch.elapsed < const Duration(seconds: 12)) {
          cancel.check();
          if (host.error != null) throw StateError(host.error!);
          final snapshot = await hosts.api
              .inspect(host.id, page.regionSelector)
              .timeout(const Duration(seconds: 2));
          if (snapshot.error.isNotEmpty) throw StateError(snapshot.error);
          if (snapshot.challenge || snapshot.interactionRequired) {
            throw StateError('发布页需要人机验证或手动交互');
          }
          if (snapshot.ready) {
            // Filter every configured publishing host, including redirects and backups.
            final denied = {
              ...publishingHosts,
              if (snapshot.url.startsWith('http')) webUri(snapshot.url).host,
            };
            final sourcePageKeys = <String>{webPageKey(page.url)};
            if (snapshot.url.startsWith('http')) {
              sourcePageKeys.add(webPageKey(webUri(snapshot.url)));
            }
            extracted = snapshot.links
                .map(Uri.tryParse)
                .whereType<Uri>()
                .where(
                  (u) =>
                      ['http', 'https'].contains(u.scheme) &&
                      u.userInfo.isEmpty &&
                      !denied.contains(u.host) &&
                      !publishingPageKeys.contains(webPageKey(u)) &&
                      !sourcePageKeys.contains(webPageKey(u)),
                )
                .map((u) => u.removeFragment())
                .toSet()
                .take(40)
                .toList();
            if (extracted.isNotEmpty) break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (extracted == null || extracted.isEmpty) {
          throw StateError('最新地址区域没有有效站点，请检查选择器（缓存已保留）');
        }
        await db.transaction(() async {
          cancel.check();
          await db.deleteCandidatesByUrls([
            page.url.toString(),
            webPageKey(page.url),
          ], profileId: page.profileId);
          for (final uri in extracted!) {
            await db.addCandidate(uri, profileId: page.profileId);
            added++;
          }
          await db.profilePageRefreshed(page.id);
        });
      } on Cancelled {
        rethrow;
      } catch (e) {
        await db.profilePageRefreshed(page.id, error: e.toString());
      } finally {
        if (host != null) await hosts.destroy(host);
      }
    }
    return added;
  }
}
