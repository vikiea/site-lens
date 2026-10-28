import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../settings/app_settings.dart';
import '../web_host/web_host.g.dart';

enum SecureDnsResolutionStatus { idle, resolving, success, fallback, failed }

enum SecureDnsResolutionSource { secureDns, systemDns, literal }

class SecureDnsResolution {
  const SecureDnsResolution({
    required this.status,
    required this.source,
    required this.provider,
    required this.epoch,
    this.hostname,
    this.error,
  });

  const SecureDnsResolution.idle(SecureDnsProvider provider, int epoch)
    : this(
        status: SecureDnsResolutionStatus.idle,
        source: SecureDnsResolutionSource.systemDns,
        provider: provider,
        epoch: epoch,
      );

  final SecureDnsResolutionStatus status;
  final SecureDnsResolutionSource source;
  final SecureDnsProvider provider;
  final int epoch;
  final String? hostname;
  final String? error;

  bool get succeeded =>
      status == SecureDnsResolutionStatus.success ||
      status == SecureDnsResolutionStatus.fallback;

  bool get usedSystemFallback => status == SecureDnsResolutionStatus.fallback;
}

class SecureDnsResolver extends ChangeNotifier {
  static const resolutionTimeout = Duration(seconds: 5);
  static const secureAttemptTimeout = Duration(seconds: 3);

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
  int _providerEpoch = 0;
  SecureDnsResolution _resolution = const SecureDnsResolution.idle(
    SecureDnsProvider.off,
    0,
  );

  SecureDnsProvider get provider => _provider;
  int get providerEpoch => _providerEpoch;
  SecureDnsResolution get resolution => _resolution;
  SecureDnsResolution get lastResolution => _resolution;

  void setProvider(SecureDnsProvider provider) {
    if (_provider == provider) return;
    _provider = provider;
    _providerEpoch++;
    _publish(SecureDnsResolution.idle(_provider, _providerEpoch));
    final clear = _clearCache;
    if (clear != null) {
      unawaited(clear().catchError((_) {}));
    }
  }

  Future<List<InternetAddress>> resolve(String hostname) async {
    final literal = InternetAddress.tryParse(hostname);
    if (literal != null) {
      _publish(
        SecureDnsResolution(
          status: SecureDnsResolutionStatus.success,
          source: SecureDnsResolutionSource.literal,
          provider: _provider,
          epoch: _providerEpoch,
          hostname: hostname,
        ),
      );
      return [literal];
    }

    final deadline = Stopwatch()..start();
    while (true) {
      final provider = _provider;
      final epoch = _providerEpoch;
      final remaining = _remaining(deadline);
      if (remaining <= Duration.zero) {
        return _systemFailure(
          hostname,
          provider,
          epoch,
          TimeoutException('secure DNS resolution timed out'),
        );
      }
      final api = _api;
      final secureEnabled =
          _androidEnabled && api != null && provider != SecureDnsProvider.off;
      _publish(
        SecureDnsResolution(
          status: SecureDnsResolutionStatus.resolving,
          source: secureEnabled
              ? SecureDnsResolutionSource.secureDns
              : SecureDnsResolutionSource.systemDns,
          provider: provider,
          epoch: epoch,
          hostname: hostname,
        ),
      );

      Object? secureError;
      if (secureEnabled) {
        try {
          final secureTimeout = remaining < secureAttemptTimeout
              ? remaining
              : secureAttemptTimeout;
          final values = await api
              .resolveSecureDns(provider.wireId, hostname)
              .timeout(secureTimeout);
          final addresses = values
              .map(InternetAddress.tryParse)
              .whereType<InternetAddress>()
              .toList(growable: false);
          if (epoch == _providerEpoch && addresses.isNotEmpty) {
            _publish(
              SecureDnsResolution(
                status: SecureDnsResolutionStatus.success,
                source: SecureDnsResolutionSource.secureDns,
                provider: provider,
                epoch: epoch,
                hostname: hostname,
              ),
            );
            return addresses;
          }
        } catch (error) {
          secureError = error;
        }
        // A provider switch invalidates the result and starts a new lookup
        // with the original deadline. Never publish or return stale answers.
        if (epoch != _providerEpoch) continue;
      }

      final systemRemaining = _remaining(deadline);
      if (systemRemaining <= Duration.zero) {
        return _systemFailure(hostname, provider, epoch, secureError);
      }
      try {
        final addresses = await _systemLookup(hostname)
            .timeout(systemRemaining);
        if (epoch != _providerEpoch) continue;
        if (addresses.isEmpty) {
          throw StateError('system DNS returned no address');
        }
        _publish(
          SecureDnsResolution(
            status: secureEnabled
                ? SecureDnsResolutionStatus.fallback
                : SecureDnsResolutionStatus.success,
            source: SecureDnsResolutionSource.systemDns,
            provider: provider,
            epoch: epoch,
            hostname: hostname,
            error: secureError?.toString(),
          ),
        );
        return addresses;
      } catch (error) {
        if (epoch != _providerEpoch) continue;
        return _systemFailure(hostname, provider, epoch, error);
      }
    }
  }

  Duration _remaining(Stopwatch stopwatch) {
    final remaining = resolutionTimeout - stopwatch.elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  List<InternetAddress> _systemFailure(
    String hostname,
    SecureDnsProvider provider,
    int epoch,
    Object? error,
  ) {
    _publish(
      SecureDnsResolution(
        status: SecureDnsResolutionStatus.failed,
        source: SecureDnsResolutionSource.systemDns,
        provider: provider,
        epoch: epoch,
        hostname: hostname,
        error: error?.toString(),
      ),
    );
    final failure = error ?? StateError('DNS resolution failed');
    Error.throwWithStackTrace(failure, StackTrace.current);
  }

  void _publish(SecureDnsResolution next) {
    _resolution = next;
    notifyListeners();
  }
}
