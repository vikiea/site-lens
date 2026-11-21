import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';

void main() {
  final profile = SiteProfile(
    id: 7,
    name: '档案七',
    createdAt: DateTime.utc(2026, 1, 1),
  );

  test('按地址解析未命中时给出明确的「暂无适配器」，不抛异常', () async {
    final registry = SiteAdapterRegistry([
      _FakeAdapter(
        id: 'alpha',
        profileId: 1,
        addresses: [Uri.parse('https://alpha.example/')],
      ),
    ]);

    final resolution = await registry.byAddress(
      Uri.parse('https://stranger.example/play/1'),
    );

    expect(resolution, isA<SiteAdapterMissing>());
    final missing = (resolution as SiteAdapterMissing).noAdapter;
    expect(
      missing.requestedAddress,
      Uri.parse('https://stranger.example/play/1'),
    );
    expect(missing.requestedProfileId, isNull);
    expect(missing.byAddress, isTrue);
    expect(missing.adapterCount, 1);
  });

  test('按档案解析未命中时同样给出明确的「暂无适配器」', () async {
    final registry = SiteAdapterRegistry([
      _FakeAdapter(
        id: 'alpha',
        profileId: 1,
        addresses: [Uri.parse('https://alpha.example/')],
      ),
    ]);

    final resolution = await registry.byProfile(profile);

    expect(resolution, isA<SiteAdapterMissing>());
    final missing = (resolution as SiteAdapterMissing).noAdapter;
    expect(missing.requestedProfileId, 7);
    expect(missing.requestedAddress, isNull);
    expect(missing.byAddress, isFalse);
    expect(missing.adapterCount, 1);
  });

  test('按地址命中：路径与查询不参与判定，主机与端口才参与', () async {
    final registry = SiteAdapterRegistry([
      _FakeAdapter(
        id: 'alpha',
        profileId: 1,
        addresses: [Uri.parse('https://alpha.example/')],
      ),
    ]);

    final resolution = await registry.byAddress(
      Uri.parse('https://alpha.example/play/9?from=share#t=30'),
    );
    expect(resolution, isA<SiteAdapterFound>());
    expect((resolution as SiteAdapterFound).adapter.profileId, 1);

    // A different port is a different origin, i.e. a different site.
    final otherPort = await registry.byAddress(
      Uri.parse('https://alpha.example:8443/'),
    );
    expect(otherPort, isA<SiteAdapterMissing>());
  });

  test('多个适配器时各自按档案解析，注册更多适配器不改调用方也可见', () async {
    final alpha = _FakeAdapter(
      id: 'alpha',
      profileId: 1,
      addresses: [Uri.parse('https://alpha.example/')],
    );
    final beta = _FakeAdapter(
      id: 'beta',
      profileId: 2,
      addresses: [Uri.parse('https://beta.example/')],
    );
    final alphaProfile = SiteProfile(
      id: 1,
      name: '档案一',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final betaProfile = SiteProfile(
      id: 2,
      name: '档案二',
      createdAt: DateTime.utc(2026, 1, 1),
    );

    final first = SiteAdapterRegistry([alpha]);
    final second = first.withAdapter(beta);

    expect((await first.byProfile(alphaProfile)).adapterOrNull, same(alpha));
    expect((await second.byProfile(alphaProfile)).adapterOrNull, same(alpha));
    expect((await second.byProfile(betaProfile)).adapterOrNull, same(beta));
    // The caller that resolved before the registry grew cannot see beta yet.
    expect(await first.byProfile(betaProfile), isA<SiteAdapterMissing>());
    expect(first.adapters, [alpha]);
    expect(second.adapters, [alpha, beta]);
  });

  test('重复的适配器 id 或重复的档案绑定在注册时被拒绝', () async {
    final alpha = _FakeAdapter(
      id: 'alpha',
      profileId: 1,
      addresses: [Uri.parse('https://alpha.example/')],
    );
    final registry = SiteAdapterRegistry([alpha]);

    // Two adapters cannot own one profile: resolution would be ambiguous.
    expect(
      () => registry.withAdapter(
        _FakeAdapter(
          id: 'gamma',
          profileId: 1,
          addresses: [Uri.parse('https://gamma.example/')],
        ),
      ),
      throwsA(
        isA<SiteAdapterRegistrationError>().having(
          (e) => e.code,
          'code',
          SiteAdapterRegistrationErrorCode.duplicateProfile,
        ),
      ),
    );

    // Ids are the registry's handle for diagnostics, so they stay unique too.
    expect(
      () => registry.withAdapter(
        _FakeAdapter(
          id: 'alpha',
          profileId: 9,
          addresses: [Uri.parse('https://delta.example/')],
        ),
      ),
      throwsA(
        isA<SiteAdapterRegistrationError>().having(
          (e) => e.code,
          'code',
          SiteAdapterRegistrationErrorCode.duplicateId,
        ),
      ),
    );
    expect(registry.adapters, [alpha]);
  });
}

/// Minimal adapter double: this file only exercises the registry's resolution
/// paths, so the content methods stay unimplemented.
class _FakeAdapter implements SiteAdapter {
  const _FakeAdapter({
    required this.id,
    required this.profileId,
    required this.addresses,
  });

  @override
  final String id;

  @override
  final int profileId;

  @override
  final List<Uri> addresses;

  @override
  SiteCredential get credential => const SiteCredential.empty();

  @override
  bool matchesAddress(Uri address) => addresses.any(
    (known) => known.host == address.host && known.port == address.port,
  );

  @override
  Future<TheaterFeed> theater(CancellationSignal cancel) =>
      throw UnimplementedError();

  @override
  Future<SeriesEpisodes> episodes(
    String seriesKey,
    CancellationSignal cancel,
  ) => throw UnimplementedError();

  @override
  Future<List<Line>> lines(
    String seriesKey,
    int episodeNumber,
    CancellationSignal cancel,
  ) => throw UnimplementedError();

  @override
  Future<List<MediaCandidate>> candidates(
    Line line,
    CancellationSignal cancel,
  ) => throw UnimplementedError();

  @override
  Future<LoginEntry> loginEntry(CancellationSignal cancel) =>
      throw UnimplementedError();

  @override
  Future<LoginVerdict> loginVerdict(CancellationSignal cancel) =>
      throw UnimplementedError();

  @override
  Future<List<BaseStation>> liveStations(CancellationSignal cancel) =>
      throw UnimplementedError();

  @override
  Future<AdapterHealth> health(CancellationSignal cancel) =>
      throw UnimplementedError();

  @override
  Future<LoginVerdict> signIn(
    SiteCredentialUpdate update,
    CancellationSignal cancel,
  ) => throw UnimplementedError();

  @override
  Future<SiteCredential> refreshCredential(CancellationSignal cancel) =>
      throw UnimplementedError();

  @override
  Future<void> signOut(CancellationSignal cancel) => throw UnimplementedError();
}
