import '../domain/models.dart';
import '../domain/site_adapter.dart';
import 'native_hosts.dart';
import '../site_credentials/site_credential_store.dart';
import 'web_host.g.dart';

/// Where the user was when they tapped 登录, so the login container can hand
/// them back to that exact place instead of the theater home.
///
/// It is a value, not a callback: the container only ever closes and reports
/// this back, and the screen that pushed the login flow re-applies it. Keeping
/// it a value is what makes "回到发起登录时的位置" testable without a navigator.
class LoginOrigin {
  const LoginOrigin({
    this.returnTo = LoginReturnTarget.theater,
    this.seriesKey,
  });

  static const theater = LoginOrigin();

  final LoginReturnTarget returnTo;

  /// The series whose detail page is being shown, when [returnTo] needs it.
  final String? seriesKey;
}

/// The screens a login can be started from.
enum LoginReturnTarget { theater, seriesDetail, episodeList }

/// A login container that is open and waiting for the user to finish on the
/// site's own login page.
class LoginEntryHandle {
  LoginEntryHandle({
    required this.hostId,
    required this.profileId,
    required this.loginUrl,
    required this.origin,
    required this.requiresPrivateProbes,
  });

  /// The host that shows the login page. Login purposes reuse the existing
  /// host, not a second browser implementation.
  final int hostId;
  final int profileId;
  final Uri loginUrl;
  final LoginOrigin origin;

  /// Whether this platform's login host runs in a private, non-shared data
  /// partition. Reported so a caller can explain a site that refuses to log in
  /// to a clean profile; never asserted, because login must work on hosts
  /// without private probes.
  final bool requiresPrivateProbes;
}

/// The outcome of asking a login container whether the user is through.
sealed class LoginOutcome {
  const LoginOutcome();
}

/// The user is not signed in yet; keep the container and ask again.
class LoginPending extends LoginOutcome {
  const LoginPending({required this.hostId});
  final int hostId;
}

/// Signed in. The container is already closed, the credential is already
/// stored, and [returnTo] is where the user came from — not the home screen.
class LoginSucceeded extends LoginOutcome {
  const LoginSucceeded({
    required this.profileId,
    required this.credential,
    required this.returnTo,
    this.seriesKey,
    required this.loginHostId,
  });

  final int profileId;

  /// The stored credential, so a caller can act on the session it now holds.
  /// Diagnostics built from this object must never print it.
  final SiteCredential credential;

  final LoginReturnTarget returnTo;
  final String? seriesKey;

  /// The container that was closed; kept for lineage in history entries.
  final int loginHostId;

  /// Whether the container was closed by this outcome.
  bool get hostClosed => true;
}

/// The container could not establish a session that the app can use. The
/// container stays open so the user can try again on the page.
class LoginFailed extends LoginOutcome {
  const LoginFailed({required this.hostId, required this.reason});
  final int hostId;

  /// Short, site-neutral and credential-free.
  final String reason;
}

/// Runs the login container for one site profile (T3).
///
/// The flow is deliberately small: open a [HostPurpose.login] host at the URL
/// the adapter names, let the user sign in on the site's own page, ask the
/// adapter for a verdict, store the credential, close the host and report
/// [LoginOrigin]. It performs no playback and never pushes a credential to
/// native — that is T4 (ADR-0007).
class LoginFlow {
  LoginFlow({
    required this.adapters,
    required this.hosts,
    required this.credentials,
  });

  final SiteAdapterRegistry adapters;
  final NativeHosts hosts;
  final SiteCredentialStore credentials;

  /// Why the most recent [begin] opened nothing, when it opened nothing.
  /// A miss is an answer, not a failure (ADR-0004).
  Object? lastMiss;

  /// Opens the login container for [profileId].
  ///
  /// Returns null when there is no adapter for the profile, when the adapter's
  /// login page is not a page the host may load, or when the host cannot be
  /// created. [lastMiss] says which.
  Future<LoginEntryHandle?> begin(
    int profileId,
    CancellationSignal cancel, {
    LoginOrigin origin = LoginOrigin.theater,
  }) async {
    lastMiss = null;
    final resolution = await adapters.byProfile(
      SiteProfile(id: profileId, name: '', createdAt: DateTime.utc(2020)),
    );
    final adapter = resolution.adapterOrNull;
    if (adapter == null) {
      lastMiss = switch (resolution) {
        SiteAdapterMissing(:final noAdapter) => noAdapter,
        _ => NoSiteAdapter.profile(profileId, adapterCount: 0),
      };
      return null;
    }

    cancel.throwIfCancelled();
    final loginEntry = await adapter.loginEntry(cancel);
    final url = loginEntry.url;
    if (!_isLoadableLoginPage(url)) {
      lastMiss = FormatException('登录页地址无效：${url.scheme}');
      return null;
    }

    final session = await hosts.create(HostPurpose.login, profileId: profileId);
    // A login page is a plain page: the app never runs user scripts against it
    // and never asks the platform for probe isolation.
    await hosts.configure(session);
    await hosts.navigate(session, url);
    return LoginEntryHandle(
      hostId: session.id,
      profileId: profileId,
      loginUrl: url,
      origin: origin,
      requiresPrivateProbes: false,
    );
  }

  /// Asks the adapter whether [entry] is signed in and acts on the answer.
  ///
  /// A pending answer leaves everything as it is. A success stores the
  /// credential first and closes the container second, so a container is never
  /// gone while the session it produced is unrecorded. A verdict that claims
  /// success without a usable credential is treated as a failure: 分片与 CDN
  /// 常只认 cookie, and an unusable pair cannot play anything.
  Future<LoginOutcome> check(
    LoginEntryHandle entry,
    CancellationSignal cancel,
  ) async {
    final session = hosts.sessions[entry.hostId];
    if (session == null || session.disposed) {
      return LoginFailed(hostId: entry.hostId, reason: '登录容器已关闭');
    }
    final adapter = _adapterFor(entry.profileId);
    if (adapter == null) {
      return LoginFailed(hostId: entry.hostId, reason: '暂无适配器');
    }

    final verdict = await adapter.loginVerdict(cancel);
    if (!verdict.loggedIn) {
      return LoginPending(hostId: entry.hostId);
    }
    if (!verdict.credential.isUsable) {
      return LoginFailed(
        hostId: entry.hostId,
        reason: '站点判定登录成功，但凭证缺少访问令牌或 cookie',
      );
    }

    await credentials.save(entry.profileId, verdict.credential);
    await close(entry);
    return LoginSucceeded(
      profileId: entry.profileId,
      credential: verdict.credential,
      returnTo: entry.origin.returnTo,
      seriesKey: entry.origin.seriesKey,
      loginHostId: entry.hostId,
    );
  }

  /// Abandons the login: closes the container and drops whatever the adapter
  /// may have produced in the meantime, so an abandoned attempt cannot leave a
  /// half-session behind.
  Future<void> abandon(LoginEntryHandle entry) async {
    await _adapterFor(entry.profileId)?.signOut(_neverCancelled);
    await credentials.clear(entry.profileId);
    await close(entry);
  }

  /// Closes the container. Safe to call twice.
  Future<void> close(LoginEntryHandle entry) async {
    final session = hosts.sessions[entry.hostId];
    if (session == null) return;
    await hosts.destroy(session);
  }

  SiteAdapter? _adapterFor(int profileId) =>
      adapters.resolveProfile(profileId)?.adapter;

  /// Login pages are ordinary web pages: only the two schemes the browser host
  /// loads are allowed, and only with a host.
  static bool _isLoadableLoginPage(Uri url) =>
      {'https', 'http'}.contains(url.scheme) &&
      url.host.isNotEmpty &&
      url.userInfo.isEmpty;

  static final _neverCancelled = CancellationSignal();
}
