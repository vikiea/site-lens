import 'dart:async';
import 'dart:io';

import '../settings/app_settings.dart';
import '../web_host/web_host.g.dart';

class SecureDnsResolver {
  SecureDnsResolver({
    AppRuntimeApi? api,
    bool? androidEnabled,
    Future<List<InternetAddress>> Function(String)? systemLookup,
    Future<void> Function()? clearCache,
  }) : _api = api ?? (Platform.isAndroid ? AppRuntimeApi() : null),
       _androidEnabled = androidEnabled ?? Platform.isAndroid,
       _systemLookup = systemLookup ?? InternetAddress.lookup,
       _clearCache =
           clearCache ??
           (api == null && Platform.isAndroid
               ? AppRuntimeApi().clearSecureDnsCache
               : null);

  final AppRuntimeApi? _api;
  final bool _androidEnabled;
  final Future<List<InternetAddress>> Function(String) _systemLookup;
  final Future<void> Function()? _clearCache;
  SecureDnsProvider _provider = SecureDnsProvider.off;

  SecureDnsProvider get provider => _provider;

  void setProvider(SecureDnsProvider provider) {
    if (_provider == provider) return;
    _provider = provider;
    final clear = _clearCache;
    if (clear != null) {
      unawaited(clear().catchError((_) {}));
    }
  }

  Future<List<InternetAddress>> resolve(String hostname) async {
    final literal = InternetAddress.tryParse(hostname);
    if (literal != null) return [literal];
    final api = _api;
    if (!_androidEnabled || api == null || _provider == SecureDnsProvider.off) {
      return _systemLookup(hostname);
    }
    try {
      final values = await api
          .resolveSecureDns(_provider.wireId, hostname)
          .timeout(const Duration(seconds: 5));
      final addresses = values
          .map(InternetAddress.tryParse)
          .whereType<InternetAddress>()
          .toList(growable: false);
      if (addresses.isNotEmpty) return addresses;
    } catch (_) {
      // DoH is advisory in this release. Preserve connectivity by falling back
      // to the system resolver when the selected provider is unavailable.
    }
    return _systemLookup(hostname);
  }
}
