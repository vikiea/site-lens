import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/site_credentials/site_credential_store.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/web_host/web_host.g.dart';
import 'package:site_lens/web_host/login_flow.dart';
import 'package:site_lens/web_host/native_hosts.dart';

import 'fake_web_host_api.dart';

/// The login container: open the site's own login page in a host of its own,
/// watch until the adapter says the session is good, store the credential,
/// close the host, and put the user back where they started (T3).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSiteAdapter adapter;
  late FakeWebHostApi api;
  late NativeHosts hosts;
  late CancellationSignal cancel;
  late SiteCredentialStore credentials;
  late InMemorySecureStorage secure;

  late AppDatabase db;
  late ScriptService scripts;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final http = ControlledHttp();
    scripts = ScriptService(db, http);
    adapter = FakeSiteAdapter(
      profileId: 1,
      addresses: [Uri.parse('https://alpha.example/')],
    );
    api = FakeWebHostApi();
    credentials = SiteCredentialStore();
    secure = InMemorySecureStorage();
    secure.install();
    cancel = CancellationSignal();
  });

  tearDown(() async {
    secure.uninstall();
    for (final session in hosts.sessions.values.toList()) {
      if (!session.disposed) await hosts.destroy(session);
    }
    await db.close();
  });

  Future<LoginFlow> flow({FakeWebHostApi? hostApi}) async {
    hosts = NativeHosts(db, scripts, ControlledHttp(), api: hostApi ?? api);
    return LoginFlow(
      adapters: SiteAdapterRegistry([adapter]),
      hosts: hosts,
      credentials: credentials,
    );
  }

  test('用的是登录用途的容器，加载的是适配器给的登录页', () async {
    final login = await flow();
    final entry = await login.begin(1, cancel);
    expect(entry, isNotNull);
    expect(api.createdPurposes[entry!.hostId], HostPurpose.login);
    expect(hosts.sessions.values.single.purpose, HostPurpose.login);
    expect(api.navigated[entry.hostId], [adapter.loginPage.toString()]);
    expect(entry.loginUrl, adapter.loginPage);
  });

  test('登录容器不申请私有探测隔离，也不装用户脚本', () async {
    final login = await flow();
    final entry = await login.begin(1, cancel);
    expect(entry, isNotNull);
    expect(entry!.requiresPrivateProbes, isFalse);
    final session = hosts.sessions[entry.hostId]!;
    // `create` consults the host's capabilities for every non-browsing purpose,
    // so the login container must not depend on private probe isolation.
    expect(api.created, contains(entry.hostId));
    expect(session.registered, isEmpty);
    expect(session.profileId, 1);
  });

  test('页面里登录成功后判定为成功，凭证落进安全存储', () async {
    final login = await flow();
    final entry = (await login.begin(1, cancel))!;
    adapter.acceptSignIn(const {'user': 'demo'});
    // The site's page posted the accepted field; the adapter now says yes.
    await adapter.signIn(
      const SiteCredentialUpdate(fields: {'user': 'demo'}),
      cancel,
    );

    final outcome = await login.check(entry, cancel);
    expect(outcome, isA<LoginSucceeded>());
    final succeeded = outcome as LoginSucceeded;
    expect(succeeded.credential.accessToken, 'fake-access-token');
    expect(succeeded.credential.cookies, {'sid': 'fake-session'});
    final stored = await credentials.read(1);
    expect(stored, isNotNull);
    expect(stored!.accessToken, 'fake-access-token');
    expect(stored.cookies, {'sid': 'fake-session'});
  });

  test('登录成功后容器关闭，且回到发起登录的位置', () async {
    final login = await flow();
    const origin = LoginOrigin(
      returnTo: LoginReturnTarget.seriesDetail,
      seriesKey: 's-1',
    );
    final entry = (await login.begin(1, cancel, origin: origin))!;
    adapter.acceptSignIn(const {'user': 'demo'});
    await adapter.signIn(
      const SiteCredentialUpdate(fields: {'user': 'demo'}),
      cancel,
    );

    final outcome = await login.check(entry, cancel);
    expect(outcome, isA<LoginSucceeded>());
    final succeeded = outcome as LoginSucceeded;
    expect(api.destroyed, contains(entry.hostId));
    // A closed host is gone from the session map rather than left behind
    // holding a disposed handle.
    expect(hosts.sessions.containsKey(entry.hostId), isFalse);
    expect(succeeded.returnTo, origin.returnTo);
    expect(succeeded.seriesKey, 's-1');
    expect(succeeded.loginHostId, entry.hostId);
  });

  test('还没登录时容器留着，不发凭证', () async {
    final login = await flow();
    final entry = (await login.begin(1, cancel))!;
    final outcome = await login.check(entry, cancel);
    expect(outcome, isA<LoginPending>());
    expect(api.destroyed, isEmpty);
    expect(hosts.sessions[entry.hostId]!.disposed, isFalse);
    expect(await credentials.read(1), isNull);
  });

  test('判定成功但凭证不可用时不关闭容器，也不落盘', () async {
    adapter = FakeSiteAdapter(
      profileId: 1,
      addresses: [Uri.parse('https://alpha.example/')],
    );
    final login = await flow();
    final entry = (await login.begin(1, cancel))!;
    // A verdict that claims success without the cookie+token pair.
    final login2 = LoginFlow(
      adapters: SiteAdapterRegistry([_HalfVerdictAdapter(adapter)]),
      hosts: hosts,
      credentials: credentials,
    );
    final outcome = await login2.check(entry, cancel);
    expect(outcome, isA<LoginFailed>());
    expect(api.destroyed, isEmpty);
    expect(await credentials.read(1), isNull);
  });

  test('放弃登录会关掉容器并清掉中途留下的凭证', () async {
    final login = await flow();
    final entry = (await login.begin(1, cancel))!;
    adapter.acceptSignIn(const {'user': 'demo'});
    await adapter.signIn(
      const SiteCredentialUpdate(fields: {'user': 'demo'}),
      cancel,
    );

    await login.abandon(entry);
    expect(api.destroyed, contains(entry.hostId));
    expect(await credentials.read(1), isNull);
  });

  test('没有适配器时明确回答暂无适配器，不开容器', () async {
    final login = await flow();
    final outcome = await login.begin(2, cancel);
    expect(outcome, isNull);
    expect(login.lastMiss, isA<NoSiteAdapter>());
    expect(api.created, isEmpty);
  });

  test('登录页地址无效时不启动容器', () async {
    adapter.loginPage = Uri.parse('ftp://alpha.example/login');
    final login = await flow();
    expect(await login.begin(1, cancel), isNull);
    expect(api.created, isEmpty);
  });

  test('登录用途不影响既有两种用途的行为', () async {
    final login = await flow();
    final browse = await hosts.create(HostPurpose.browsing);
    final probe = await hosts.create(HostPurpose.discovery);
    final verify = await hosts.create(HostPurpose.verification);
    final signIn = await hosts.create(HostPurpose.login);

    expect(browse.purpose, HostPurpose.browsing);
    expect(probe.purpose, HostPurpose.discovery);
    expect(verify.purpose, HostPurpose.verification);
    expect(signIn.purpose, HostPurpose.login);

    // Enum ordinals keep the prior values; a new value is appended, never
    // inserted, so existing wire values keep their meaning.
    expect(HostPurpose.browsing.index, 0);
    expect(HostPurpose.discovery.index, 1);
    expect(HostPurpose.verification.index, 2);
    expect(HostPurpose.login.index, 3);

    final script = await scripts.save(
      '// ==UserScript==\n'
      '// @name login-flow fixture\n'
      '// @match https://alpha.example/*\n'
      '// @grant SiteLens.registerMedia\n'
      '// ==/UserScript==',
    );
    await scripts.enable(
      script,
      Cancellation(),
      networkMode: ScriptNetworkMode.public,
      publicConfirmed: true,
    );

    await hosts.configure(browse);
    expect(browse.registered, isNotEmpty, reason: '浏览用途仍装脚本');
    await hosts.configure(probe);
    expect(probe.registered, isEmpty, reason: '探测用途仍不装脚本');
    await hosts.configure(verify);
    expect(verify.registered, isEmpty);
    await hosts.configure(signIn);
    expect(signIn.registered, isEmpty);

    expect(login, isNotNull);
  });
}

/// Wraps a fake so [loginVerdict] reports the given verdict, which is how a
/// bogus "logged in" answer is exercised without a site to ask.
class _HalfVerdictAdapter implements SiteAdapter {
  _HalfVerdictAdapter(this.inner);

  final SiteAdapter inner;

  static const _half = LoginVerdict(
    loggedIn: true,
    credential: SiteCredential(accessToken: 'only-token', cookies: {}),
  );

  @override
  Future<LoginVerdict> loginVerdict(CancellationSignal cancel) async => _half;

  @override
  Future<LoginEntry> loginEntry(CancellationSignal cancel) =>
      inner.loginEntry(cancel);

  @override
  String get id => inner.id;

  @override
  int get profileId => inner.profileId;

  @override
  List<Uri> get addresses => inner.addresses;

  @override
  SiteCredential get credential => inner.credential;

  @override
  bool matchesAddress(Uri address) => inner.matchesAddress(address);

  @override
  Future<TheaterFeed> theater(CancellationSignal cancel) =>
      inner.theater(cancel);

  @override
  Future<SeriesEpisodes> episodes(
    String seriesKey,
    CancellationSignal cancel,
  ) => inner.episodes(seriesKey, cancel);

  @override
  Future<List<Line>> lines(
    String seriesKey,
    int episodeNumber,
    CancellationSignal cancel,
  ) => inner.lines(seriesKey, episodeNumber, cancel);

  @override
  Future<List<MediaCandidate>> candidates(
    Line line,
    CancellationSignal cancel,
  ) => inner.candidates(line, cancel);

  @override
  Future<LoginVerdict> signIn(
    SiteCredentialUpdate update,
    CancellationSignal cancel,
  ) => inner.signIn(update, cancel);

  @override
  Future<SiteCredential> refreshCredential(CancellationSignal cancel) =>
      inner.refreshCredential(cancel);

  @override
  Future<void> signOut(CancellationSignal cancel) => inner.signOut(cancel);

  @override
  Future<List<BaseStation>> liveStations(CancellationSignal cancel) =>
      inner.liveStations(cancel);

  @override
  Future<AdapterHealth> health(CancellationSignal cancel) =>
      inner.health(cancel);
}

/// Stand-in for the `flutter_secure_storage` platform channel. Widget tests
/// have no native keystore, so the channel has to be answered in-process; the
/// store still exercises its real encode/decode and key scheme.
class InMemorySecureStorage {
  final values = <String, String>{};
  static const channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          final key = arguments['key'] as String;
          switch (call.method) {
            case 'write':
            case 'writeAll':
              values[key] = arguments['value'] as String;
              return null;
            case 'read':
            case 'readAll':
              final value = values[key];
              return call.method == 'readAll' ? Map.of(values) : value;
            case 'delete':
              values.remove(key);
              return null;
            case 'deleteAll':
              values.clear();
              return null;
            case 'containsKey':
              return values.containsKey(key);
            default:
              return null;
          }
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    values.clear();
  }
}
