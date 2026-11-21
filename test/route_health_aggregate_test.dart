import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/domain/route_health.dart';

RouteObservation _route(
  SiteRoute route,
  RouteHealthState state, {
  String? failureCategory,
  String? failureDetail,
  String? stationKey,
  SitePageObservation? page,
}) => RouteObservation(
  route: route,
  state: state,
  checkedAt: DateTime(2026, 11, 21, 12),
  failureCategory: failureCategory,
  failureDetail: failureDetail,
  stationKey: stationKey,
  pages: [?page],
);

SitePageObservation _page(
  String host,
  SiteRoute route,
  PageHealthState state, {
  String? failureCategory,
  String? failureDetail,
  DateTime? refreshedAt,
}) => SitePageObservation(
  pageId: host.hashCode,
  url: Uri.parse('https://$host/latest'),
  route: route,
  state: state,
  refreshedAt: refreshedAt ?? DateTime(2026, 11, 21, 12),
  failureCategory: failureCategory,
  failureDetail: failureDetail,
);

void main() {
  group('站点档案徽章是出口的聚合', () {
    test('任一出口可用，档案就可用', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(SiteRoute.direct, RouteHealthState.failing),
          _route(SiteRoute.browse, RouteHealthState.ok),
        ],
      );

      expect(record.state, ProfileHealthState.ok);
      expect(record.isUsable, isTrue);
      expect(record.failedRoutes, {SiteRoute.direct});
    });

    test('全部出口都失败，档案才报故障', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(SiteRoute.direct, RouteHealthState.failing),
          _route(SiteRoute.browse, RouteHealthState.failing),
        ],
      );

      expect(record.state, ProfileHealthState.failing);
      expect(record.isUsable, isFalse);
    });

    test('一个出口失败、另一个还没被检查过，不报故障', () {
      // 「未检查」不是「不可用」：把没跑过的出口算成故障，等于凭空宣布站点挂了。
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(SiteRoute.direct, RouteHealthState.failing),
          _route(SiteRoute.browse, RouteHealthState.unknown),
        ],
      );

      expect(record.state, ProfileHealthState.unknown);
      expect(record.failedRoutes, {SiteRoute.direct});
    });

    test('没有任何出口记录时是未检查', () {
      expect(
        RouteHealthRecord(profileId: 1, routes: const []).state,
        ProfileHealthState.unknown,
      );
    });
  });

  group('失败文案指出哪条出口失败', () {
    test('只有直连出口失败时点名直连出口', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(SiteRoute.direct, RouteHealthState.failing),
          _route(SiteRoute.browse, RouteHealthState.ok),
        ],
      );

      expect(record.summary, contains('直连出口'));
      // The browse route kept working, so it is never named as a failure.
      expect(record.summary, isNot(contains('浏览出口不可用')));
    });

    test('两条出口都失败时两条都点名', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(SiteRoute.direct, RouteHealthState.failing),
          _route(SiteRoute.browse, RouteHealthState.failing),
        ],
      );

      expect(routeFailureSentence(record), contains('直连出口'));
      expect(routeFailureSentence(record), contains('浏览出口'));
    });

    test('出口的失败分类被翻成人话', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(
            SiteRoute.direct,
            RouteHealthState.failing,
            failureCategory: 'tls_handshake',
          ),
        ],
      );

      expect(record.summary, contains('TLS 握手失败'));
    });

    test('只有确实不可用的出口进徽章文案，失败页仍留在该出口的记录里', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(
            SiteRoute.direct,
            RouteHealthState.failing,
            page: _page(
              'api.example',
              SiteRoute.direct,
              PageHealthState.failing,
              failureCategory: 'timeout',
            ),
          ),
          _route(
            SiteRoute.browse,
            RouteHealthState.ok,
            page: _page(
              'mirror.example',
              SiteRoute.browse,
              PageHealthState.failing,
              failureCategory: 'dns',
            ),
          ),
        ],
      );

      final sentence = routeFailureSentence(record)!;
      expect(sentence, allOf(contains('直连出口'), contains('api.example')));
      expect(sentence, contains('探测超时'));
      expect(sentence, isNot(contains('浏览出口')));
      expect(
        record.routeFor(SiteRoute.browse)!.failedPage?.host,
        'mirror.example',
      );
    });

    test('一切正常时没有失败文案', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [_route(SiteRoute.browse, RouteHealthState.ok)],
      );

      expect(routeFailureSentence(record), isNull);
    });
  });

  group('发布页结果带出口，落点仍是 refreshed_at / error', () {
    test('只考察档案具备的出口，忽略档案没开的出口记录', () {
      final record = RouteHealthRecord.forProfile(
        profileId: 1,
        routes: {SiteRoute.browse},
        observations: [
          _route(SiteRoute.direct, RouteHealthState.failing),
          _route(SiteRoute.browse, RouteHealthState.ok),
        ],
      );

      expect(record.state, ProfileHealthState.ok);
      expect(record.failedRoutes, isEmpty);
      expect(record.routes.map((r) => r.route), [SiteRoute.browse]);
    });

    test('出口状态也按发布页聚合：任一发布页可用即该出口可用', () {
      final record = RouteHealthRecord.forProfile(
        profileId: 1,
        routes: {SiteRoute.browse},
        observations: [
          RouteObservation(
            route: SiteRoute.browse,
            state: RouteHealthState.failing,
            pages: [
              _page('a.example', SiteRoute.browse, PageHealthState.failing),
              _page('b.example', SiteRoute.browse, PageHealthState.ok),
            ],
          ),
        ],
      );

      expect(
        record.routeFor(SiteRoute.browse)?.effectiveState,
        RouteHealthState.ok,
      );
    });

    test('出口没有站点级记录时，由发布页结果推导出口状态', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: const [],
        observations: [
          RouteObservation(
            route: SiteRoute.direct,
            pages: [
              _page(
                'a.example',
                SiteRoute.direct,
                PageHealthState.failing,
                failureCategory: 'timeout',
              ),
            ],
          ),
        ],
      );

      expect(
        record.routeFor(SiteRoute.direct)?.effectiveState,
        RouteHealthState.failing,
      );
      expect(record.summary, contains('探测超时'));
    });

    test('失败站点名来自发布页，便于用户认出是哪一页', () {
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [
          _route(
            SiteRoute.direct,
            RouteHealthState.failing,
            page: _page(
              'cdn.example',
              SiteRoute.direct,
              PageHealthState.failing,
              failureCategory: 'dns',
            ),
          ),
        ],
      );

      expect(record.summary, allOf(contains('cdn.example'), contains('DNS')));
    });
  });

  group('详情页呈现：当前可用基站与被试过的出口', () {
    test('基站按顺序列出，并标出首选', () {
      final view = RouteDetailView(
        record: RouteHealthRecord(
          profileId: 1,
          routes: [
            _route(SiteRoute.direct, RouteHealthState.ok, stationKey: 'a'),
            _route(SiteRoute.browse, RouteHealthState.failing),
          ],
        ),
        liveStations: [
          BaseStation(
            origin: Uri.parse('https://one.example/'),
            preferred: true,
          ),
          BaseStation(origin: Uri.parse('https://two.example/')),
        ],
      );

      expect(view.currentStations.map((s) => s.origin.host), [
        'one.example',
        'two.example',
      ]);
      expect(view.currentStations.first.preferred, isTrue);
    });

    test('被试过的出口按固定顺序给出，始终包含两条', () {
      final view = RouteDetailView(
        record: RouteHealthRecord(
          profileId: 1,
          routes: [
            _route(SiteRoute.browse, RouteHealthState.ok),
            _route(SiteRoute.direct, RouteHealthState.failing),
          ],
        ),
      );

      expect(view.attemptedRoutes, [SiteRoute.direct, SiteRoute.browse]);
    });

    test('没有可用基站时明说，而不是留白', () {
      final view = RouteDetailView(
        record: RouteHealthRecord(profileId: 1, routes: const []),
      );

      expect(view.currentStations, isEmpty);
      expect(view.hasStations, isFalse);
    });
  });

  group('存储状态映射：出口判定 + 发布页结果', () {
    ProfilePage page(
      int id,
      String host,
      SiteRoute route, {
      DateTime? refreshedAt,
      String? error,
    }) => ProfilePage(
      id: id,
      profileId: 1,
      url: Uri.parse('https://$host/latest'),
      regionSelector: 'main',
      route: route,
      refreshedAt: refreshedAt,
      error: error,
    );

    test('没有 error 的发布页算可用，有 error 的算失败并分类', () {
      final record = routeHealthFromStored(
        profileId: 1,
        routes: {SiteRoute.browse},
        pages: [
          page(1, 'ok.example', SiteRoute.browse, refreshedAt: DateTime(2026)),
          page(2, 'bad.example', SiteRoute.browse, error: 'DNS 解析失败，请检查网络后重试'),
        ],
        verdicts: const {},
      );

      final browse = record.routeFor(SiteRoute.browse)!;
      expect(browse.effectiveState, RouteHealthState.ok);
      // The failing page stays attached to the route for the detail panel,
      // but a route that still works must not turn the badge into a complaint.
      expect(browse.failedPage?.host, 'bad.example');
      expect(browse.effectiveCategory, 'dns');
      expect(routeFailureSentence(record), isNull);
    });

    test('从未刷新过的发布页是未检查，不是失败', () {
      final record = routeHealthFromStored(
        profileId: 1,
        routes: {SiteRoute.browse},
        pages: [page(1, 'new.example', SiteRoute.browse)],
        verdicts: const {},
      );

      expect(
        record.routeFor(SiteRoute.browse)!.effectiveState,
        RouteHealthState.unknown,
      );
      expect(record.state, ProfileHealthState.unknown);
      expect(routeFailureSentence(record), isNull);
    });

    test('出口没有自己的记录时，页面失败就足以把徽章压成故障', () {
      final record = routeHealthFromStored(
        profileId: 1,
        routes: {SiteRoute.browse},
        pages: [page(1, 'bad.example', SiteRoute.browse, error: '操作超时，请稍后重试')],
        verdicts: const {},
      );

      expect(record.state, ProfileHealthState.failing);
      expect(record.summary, contains('探测超时'));
    });

    test('出口判定与发布页结果打架时，更新鲜的发布页说了算', () {
      final record = routeHealthFromStored(
        profileId: 1,
        routes: {SiteRoute.direct},
        pages: [
          page(1, 'ok.example', SiteRoute.direct, refreshedAt: DateTime(2026)),
        ],
        verdicts: {
          SiteRoute.direct: ProfileHealth(
            profileId: 1,
            state: ProfileHealthState.failing,
            lastCheckedAt: DateTime(2026, 11, 21, 12),
            lastFailureCategory: 'tls_handshake',
          ),
        },
      );

      // The page answered after the last route-wide check, so it wins: a
      // stale "TLS 握手失败" must not outlive a page that answered since.
      expect(
        record.routeFor(SiteRoute.direct)!.effectiveState,
        RouteHealthState.ok,
      );
      expect(record.state, ProfileHealthState.ok);
      expect(routeFailureSentence(record), isNull);
    });

    test('页面失败分类从真实文案里认出来', () {
      expect(pageFailureCategory('操作超时，请稍后重试'), 'timeout');
      expect(pageFailureCategory('最新地址区域没有有效站点，请检查选择器（缓存已保留）'), 'selector');
      expect(pageFailureCategory('TLS/证书验证失败'), 'certificate');
      expect(pageFailureCategory('DNS 解析失败，请检查网络后重试'), 'dns');
    });
  });

  group('健康不参与排序与推荐', () {
    test('拿健康当排序键会被直接挡住：比较只看可用性与耗时', () {
      // 该记录只用于展示，没有实现 Comparable、也没有 rank/weight 字段，
      // 推荐顺序由 ProbeResult 的比较器决定，不读健康。
      expect(routeHealthFeedsRanking, isFalse);
      final record = RouteHealthRecord(
        profileId: 1,
        routes: [_route(SiteRoute.direct, RouteHealthState.ok)],
      );
      expect(record, isNot(isA<Comparable<Object>>()));
    });
  });
}
