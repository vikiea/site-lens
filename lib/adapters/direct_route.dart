import 'package:flutter/services.dart';

import '../domain/site_adapter.dart';
import '../network/transport.dart';
import '../site_credentials/site_credential_store.dart';
import 'huangguo/huangguo_adapter.dart';
import 'huangguo/huangguo_wire.dart';

/// Which site's interface a 直连出口 talks to.
///
/// The rule is deliberately data-driven and lives outside the controller: a
/// profile that publishes a page on one of a site's hosts is that site's
/// profile. Nothing here is a user setting, and nothing here is a guess about
/// a site the app has not been shown (ADR-0004: the adapter owns its own
/// mechanics, the app only decides which adapter a profile belongs to).
enum DirectRouteSite {
  /// 黄果短剧. Recognised by the hosts its own interface answers on.
  huangguo;

  /// The site [profile] belongs to, decided by the addresses it publishes.
  ///
  /// A profile that publishes nothing on a known host has no 直连出口 — the
  /// theater then has no station for it, rather than an adapter that would
  /// answer with an invented catalog.
  static DirectRouteSite? of(Iterable<Uri> addresses) {
    for (final address in addresses) {
      for (final host in HuangguoHosts.all) {
        if (host.host == address.host) return DirectRouteSite.huangguo;
      }
    }
    return null;
  }
}

/// What the site produced for this [profileId].
typedef DirectRouteAdapter = ({DirectRouteSite site, SiteAdapter adapter});

/// Builds a 直连出口 adapter for [profile] from the addresses it owns, or null
/// when no known site owns it.
///
/// [http] is injectable so tests drive the adapter through a fake transport;
/// production passes the controller's own [ControlledHttp], which keeps every
/// socket, proxy, DNS and TLS decision inside the platform's system network
/// (the same rule as scripts, hosts and filter sources).
/// [remoteSecret] is a published secret already in hand. Production leaves it
/// null and lets the adapter fetch its own; tests hand one in so the sealed
/// answers of a fake interface can be read without a second network path.
Future<DirectRouteAdapter?> createDirectRouteAdapter({
  required int profileId,
  required List<Uri> addresses,
  required ControlledHttp http,
  required SiteCredentialStore credentials,
  Uint8List? remoteSecret,
}) async {
  final site = DirectRouteSite.of(addresses);
  if (site == null || addresses.isEmpty) return null;
  final held = await credentials.read(profileId);
  switch (site) {
    case DirectRouteSite.huangguo:
      final adapter = HuangguoAdapter(
        profileId: profileId,
        addresses: List.unmodifiable(addresses),
        http: http,
        initialCredential: held ?? const SiteCredential.empty(),
        remoteSecret: remoteSecret,
      );
      return (site: site, adapter: adapter);
  }
}

/// A credential sink for adapters that hold their own session.
///
/// ADR-0007 keeps the app as the single source of truth: whatever an adapter
/// obtains from the site is written through here, and the native mirror is
/// updated by the existing push path.
Future<void> persistAdapterCredential({
  required SiteCredentialStore credentials,
  required int profileId,
  required SiteCredential credential,
  Future<void> Function(int profileId, SiteCredential credential)? after,
}) async {
  if (credential.isEmpty) {
    await credentials.clear(profileId);
  } else {
    await credentials.save(profileId, credential);
  }
  if (after != null) await after(profileId, credential);
}

/// Raises a PlatformException-shaped failure into the adapter's own error
/// vocabulary, so a caller never sees a plugin message.
SiteAdapterError credentialFailure(Object error) {
  if (error is PlatformException) {
    return SiteAdapterError(
      SiteAdapterErrorKind.credentialRejected,
      error.message ?? '会话没有被保存',
    );
  }
  return SiteAdapterError(SiteAdapterErrorKind.unavailable, '$error');
}
