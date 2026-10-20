import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'media_service.dart';

/// Minimal SSDP/AVTransport implementation for a single user-selected DLNA
/// session. Discovery and SOAP are intentionally separate from the relay so a
/// device can be used with a public MP4 URL without opening a server.
class DlnaDiscovery {
  const DlnaDiscovery({this.timeout = const Duration(seconds: 2)});
  final Duration timeout;

  static final _profiles = <String, DlnaDeviceDescription>{};

  /// Returns the service endpoints captured with [device]. The extra
  /// description is kept private to the DLNA adapter so CastDevice does not
  /// need to grow transport-specific fields.
  static DlnaDeviceDescription? profileFor(CastDevice device) =>
      _profiles[device.id];

  /// Parses a device description without sending network traffic. Keeping
  /// this public makes URLBase/service selection testable without a receiver.
  static DlnaDeviceDescription? parseDescription(String source, Uri location) {
    final urlBaseValue = _xmlValue(source, 'URLBase');
    final base = urlBaseValue == null
        ? location
        : _resolveUrl(location, urlBaseValue) ?? location;
    final services = _serviceEndpoints(source, base);
    _DlnaServiceEndpoint? avTransport;
    _DlnaServiceEndpoint? connectionManager;
    _DlnaServiceEndpoint? renderingControl;
    for (final service in services) {
      final type = service.serviceType.toLowerCase();
      if (type.contains(':avtransport:') && avTransport == null) {
        avTransport = service;
      } else if (type.contains(':connectionmanager:') &&
          connectionManager == null) {
        connectionManager = service;
      } else if (type.contains(':renderingcontrol:') &&
          renderingControl == null) {
        renderingControl = service;
      }
    }
    if (avTransport == null) return null;
    return DlnaDeviceDescription(
      descriptionUrl: location,
      baseUrl: base,
      avTransportServiceType: avTransport.serviceType,
      avTransportControlUrl: avTransport.controlUrl,
      connectionManagerServiceType: connectionManager?.serviceType,
      connectionManagerControlUrl: connectionManager?.controlUrl,
      renderingControlServiceType: renderingControl?.serviceType,
      renderingControlControlUrl: renderingControl?.controlUrl,
    );
  }

  Future<List<CastDevice>> discover() async {
    final multicast = _DlnaMulticastLock();
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    Timer? timer;
    final byLocation = <String, _SsdpResponse>{};
    try {
      await multicast.acquire();
      final activeSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      socket = activeSocket;
      activeSocket.broadcastEnabled = true;
      final request = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 1\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n',
      );
      final completer = Completer<void>();
      timer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      subscription = activeSocket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = activeSocket.receive();
          if (datagram == null) return;
          final response = _SsdpResponse.parse(
            utf8.decode(datagram.data, allowMalformed: true),
          );
          if (response.location != null) {
            byLocation[response.location!] = response;
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      );
      activeSocket.send(request, InternetAddress('239.255.255.250'), 1900);
      await completer.future;
    } finally {
      timer?.cancel();
      socket?.close();
      await subscription?.cancel();
      await multicast.release();
    }
    final devices = <CastDevice>[];
    for (final response in byLocation.values) {
      final device = await _readDevice(response);
      if (device != null) devices.add(device);
    }
    return List.unmodifiable(devices);
  }

  Future<CastDevice?> _readDevice(_SsdpResponse response) async {
    final location = response.location;
    if (location == null) return null;
    final uri = Uri.tryParse(location);
    if (uri == null) return null;
    return readDevice(uri);
  }

  /// Reads one SSDP description and its actual ConnectionManager capabilities.
  Future<CastDevice?> readDevice(Uri uri) async {
    if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      return null;
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final friendly = _xmlValue(body, 'friendlyName') ?? uri.host;
      final model = _xmlValue(body, 'modelName');
      final description = parseDescription(body, uri);
      if (description == null) return null;
      final id = sha256
          .convert(utf8.encode(description.avTransportControlUrl.toString()))
          .toString()
          .substring(0, 24);
      DlnaProtocolInfo? protocolInfo;
      final connectionManagerUrl = description.connectionManagerControlUrl;
      if (connectionManagerUrl != null) {
        final soap = DlnaSoapClient(
          description.avTransportControlUrl,
          avTransportServiceType: description.avTransportServiceType,
          connectionManagerControlUrl: connectionManagerUrl,
          connectionManagerServiceType:
              description.connectionManagerServiceType,
          renderingControlControlUrl: description.renderingControlControlUrl,
          renderingControlServiceType: description.renderingControlServiceType,
          timeout: timeout,
        );
        try {
          protocolInfo = await soap.protocolInfo();
        } catch (_) {
          // Capability discovery is fail-closed. The device can remain
          // visible, but the caller must not infer HLS/MP4 support.
        } finally {
          soap.close();
        }
      }
      _profiles[id] = description;
      return CastDevice(
        id: id,
        name: friendly,
        address: description.avTransportControlUrl,
        model: model,
        supportsMp4: protocolInfo?.supportsMime('video/mp4') ?? false,
        supportsHls:
            protocolInfo?.supportsMime('application/vnd.apple.mpegurl') ??
            false,
        supportsSeek: true,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static List<_DlnaServiceEndpoint> _serviceEndpoints(String source, Uri base) {
    final services = <_DlnaServiceEndpoint>[];
    final serviceMatches = RegExp(
      r'<(?:[A-Za-z0-9_.-]+:)?service\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?service\s*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(source);
    for (final match in serviceMatches) {
      final block = match.group(1) ?? '';
      final serviceType = _xmlValue(block, 'serviceType');
      final rawControl = _xmlValue(block, 'controlURL');
      if (serviceType == null || rawControl == null) continue;
      final controlUrl = _resolveUrl(base, rawControl);
      if (controlUrl == null) continue;
      services.add(
        _DlnaServiceEndpoint(serviceType: serviceType, controlUrl: controlUrl),
      );
    }
    return services;
  }
}

class DlnaDeviceDescription {
  const DlnaDeviceDescription({
    required this.descriptionUrl,
    required this.baseUrl,
    required this.avTransportServiceType,
    required this.avTransportControlUrl,
    this.connectionManagerServiceType,
    this.connectionManagerControlUrl,
    this.renderingControlServiceType,
    this.renderingControlControlUrl,
  });

  final Uri descriptionUrl;
  final Uri baseUrl;
  final String avTransportServiceType;
  final Uri avTransportControlUrl;
  final String? connectionManagerServiceType;
  final Uri? connectionManagerControlUrl;
  final String? renderingControlServiceType;
  final Uri? renderingControlControlUrl;
}

class _DlnaServiceEndpoint {
  const _DlnaServiceEndpoint({
    required this.serviceType,
    required this.controlUrl,
  });

  final String serviceType;
  final Uri controlUrl;
}

String? _xmlValue(String source, String name) {
  final match = RegExp(
    '<(?:[A-Za-z0-9_.-]+:)?$name\\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?$name\\s*>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(source);
  final value = match?.group(1)?.trim();
  if (value == null || value.isEmpty) return null;
  return _xmlUnescape(value);
}

String _xmlUnescape(String value) => value.replaceAllMapped(
  RegExp(r'&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);'),
  (match) {
    final entity = match.group(1)!;
    const named = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"};
    if (named.containsKey(entity)) return named[entity]!;
    final code = entity.startsWith('#x')
        ? int.tryParse(entity.substring(2), radix: 16)
        : int.tryParse(entity.substring(1));
    return code == null || code <= 0 || code > 0x10ffff
        ? match.group(0)!
        : String.fromCharCode(code);
  },
);

Uri? _resolveUrl(Uri base, String raw) {
  final value = raw.trim();
  if (Uri.tryParse(value) == null) return null;
  final result = base.resolve(value);
  if (!['http', 'https'].contains(result.scheme) || result.host.isEmpty) {
    return null;
  }
  return result;
}

class _DlnaMulticastLock {
  const _DlnaMulticastLock();
  static const _channel = MethodChannel('site_lens/dlna');

  Future<void> acquire() async {
    try {
      await _channel.invokeMethod<void>('acquireMulticastLock');
    } on MissingPluginException {
      // iOS and desktop use the system network stack without an Android lock.
    }
  }

  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('releaseMulticastLock');
    } on MissingPluginException {
      // No-op outside Android.
    }
  }
}

class _SsdpResponse {
  const _SsdpResponse(this.location);
  final String? location;

  static _SsdpResponse parse(String source) {
    for (final line in source.split(RegExp(r'\r?\n'))) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      if (line.substring(0, separator).trim().toLowerCase() == 'location') {
        return _SsdpResponse(line.substring(separator + 1).trim());
      }
    }
    return const _SsdpResponse(null);
  }
}

class DlnaUnsupportedFormatException extends StateError {
  DlnaUnsupportedFormatException({required this.mime, this.unknown = false})
    : super(
        _isHlsMime(mime)
            ? '${unknown ? '接收设备未声明支持' : '接收设备不支持'} HLS，请先转为 MP4 后再投屏'
            : '接收设备不支持当前媒体格式（$mime），请使用兼容的 MP4 文件',
      );

  final String mime;
  final bool unknown;
  String get code => MediaErrorCode.unsupported;
  bool get requiresMp4 => _isHlsMime(mime);
}

class DlnaSoapException extends StateError {
  DlnaSoapException({
    required this.action,
    required this.statusCode,
    this.upnpCode,
    this.description,
  }) : super(
         'DLNA $action 失败（${upnpCode == null ? 'HTTP $statusCode' : 'UPnP $upnpCode'}）'
         '${description == null ? '' : '：$description'}',
       );

  final String action;
  final int statusCode;
  final int? upnpCode;
  final String? description;
}

/// An optional renderer command is unavailable. The active cast session stays
/// intact so the caller can keep playback running and disable only that
/// control.
class DlnaOptionalCommandUnsupportedException extends StateError {
  DlnaOptionalCommandUnsupportedException({
    required this.action,
    String? message,
  }) : super(message ?? '接收设备不支持 $action');

  final String action;
}

class DlnaSoapClient {
  DlnaSoapClient(
    this.controlUrl, {
    HttpClient? client,
    this.avTransportServiceType = 'urn:schemas-upnp-org:service:AVTransport:1',
    this.connectionManagerControlUrl,
    String? connectionManagerServiceType,
    this.renderingControlControlUrl,
    String? renderingControlServiceType,
    this.timeout = const Duration(seconds: 5),
  }) : connectionManagerServiceType =
           connectionManagerServiceType ??
           'urn:schemas-upnp-org:service:ConnectionManager:1',
       renderingControlServiceType =
           renderingControlServiceType ??
           'urn:schemas-upnp-org:service:RenderingControl:1',
       _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
    // UPnP control is always sent to the selected LAN endpoint directly.
    _client.findProxy = (_) => 'DIRECT';
  }

  final Uri controlUrl;
  final String avTransportServiceType;
  final Uri? connectionManagerControlUrl;
  final String connectionManagerServiceType;
  final Uri? renderingControlControlUrl;
  final String renderingControlServiceType;
  final Duration timeout;
  final HttpClient _client;

  Future<void> setMedia(
    Uri mediaUrl, {
    String mime = 'video/mp4',
    String title = 'Site Lens',
    int? size,
    Duration? duration,
  }) => _action(
    'SetAVTransportURI',
    '<InstanceID>0</InstanceID><CurrentURI>${_xml(mediaUrl.toString())}</CurrentURI><CurrentURIMetaData>${_xml(_metadata(mediaUrl, mime, title, size, duration))}</CurrentURIMetaData>',
  );

  Future<void> play() =>
      _action('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  Future<void> pause() => _action('Pause', '<InstanceID>0</InstanceID>');
  Future<void> stop() => _action('Stop', '<InstanceID>0</InstanceID>');
  Future<void> seek(Duration position) => _action(
    'Seek',
    '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${_clock(position)}</Target>',
  );

  Future<int?> getVolume() async {
    final endpoint = renderingControlControlUrl;
    if (endpoint == null) return null;
    final response = await _actionResponse(
      'GetVolume',
      '<InstanceID>0</InstanceID><Channel>Master</Channel>',
      serviceType: renderingControlServiceType,
      endpoint: endpoint,
    );
    final raw = _xmlValue(response, 'CurrentVolume');
    final volume = raw == null ? null : int.tryParse(raw);
    if (volume == null || volume < 0 || volume > 100) {
      throw StateError('接收设备未返回有效的音量');
    }
    return volume;
  }

  Future<void> setVolume(int volume) async {
    final endpoint = renderingControlControlUrl;
    if (endpoint == null) {
      throw DlnaOptionalCommandUnsupportedException(action: '音量控制');
    }
    final bounded = volume.clamp(0, 100);
    await _actionResponse(
      'SetVolume',
      '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>$bounded</DesiredVolume>',
      serviceType: renderingControlServiceType,
      endpoint: endpoint,
    );
  }

  Future<String> getProtocolInfo() => _actionResponse(
    'GetProtocolInfo',
    '',
    serviceType: connectionManagerServiceType,
    endpoint: connectionManagerControlUrl ?? controlUrl,
  );

  Future<DlnaProtocolInfo> protocolInfo() async =>
      DlnaProtocolInfo.parse(await getProtocolInfo());

  bool supportsProtocol(String protocolInfo, {required String mime}) =>
      DlnaProtocolInfo.parse(protocolInfo).supportsMime(mime);

  Future<DlnaTransportInfo> transportInfo() async {
    final response = await _actionResponse(
      'GetTransportInfo',
      '<InstanceID>0</InstanceID>',
    );
    final state = _xmlValue(response, 'CurrentTransportState');
    final status = _xmlValue(response, 'CurrentTransportStatus');
    if (state == null || status == null) {
      throw StateError('接收设备未返回有效的播放状态');
    }
    return DlnaTransportInfo(state.toUpperCase(), status.toUpperCase());
  }

  Future<DlnaPositionInfo> positionInfo() async {
    final response = await _actionResponse(
      'GetPositionInfo',
      '<InstanceID>0</InstanceID>',
    );
    return DlnaPositionInfo(
      trackUri: Uri.tryParse(_xmlValue(response, 'TrackURI') ?? ''),
      position: _parseClock(_xmlValue(response, 'RelTime')),
      duration: _parseClock(_xmlValue(response, 'TrackDuration')),
    );
  }

  Future<Uri?> currentMedia() async {
    final response = await _actionResponse(
      'GetMediaInfo',
      '<InstanceID>0</InstanceID>',
    );
    return Uri.tryParse(_xmlValue(response, 'CurrentURI') ?? '');
  }

  Future<void> _action(String action, String arguments) async {
    await _actionResponse(action, arguments);
  }

  Future<String> _actionResponse(
    String action,
    String arguments, {
    String? serviceType,
    Uri? endpoint,
  }) async {
    final type = serviceType ?? avTransportServiceType;
    final body = utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$type">$arguments</u:$action></s:Body></s:Envelope>',
    );
    HttpClientRequest? pending;
    try {
      return await (() async {
        final request = await _client.postUrl(endpoint ?? controlUrl);
        pending = request;
        request.headers.contentType = ContentType(
          'text',
          'xml',
          charset: 'utf-8',
        );
        request.headers.set('SOAPACTION', '"$type#$action"');
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 512 * 1024) {
            throw StateError('接收设备的控制响应过大');
          }
          bytes.addAll(chunk);
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        final fault = RegExp(
          r'<(?:[A-Za-z0-9_.-]+:)?Fault(?:\s|>)',
          caseSensitive: false,
        ).hasMatch(text);
        if (response.statusCode < 200 || response.statusCode >= 300 || fault) {
          final rawCode = _xmlValue(text, 'errorCode');
          final code = rawCode == null ? null : int.tryParse(rawCode);
          final description = _xmlValue(text, 'errorDescription');
          throw DlnaSoapException(
            action: action,
            statusCode: response.statusCode,
            upnpCode: code,
            description: description,
          );
        }
        if (!RegExp(
          '<(?:[A-Za-z0-9_.-]+:)?${action}Response(?:\\s|/?>)',
          caseSensitive: false,
        ).hasMatch(text)) {
          throw StateError('接收设备未返回有效的 $action 响应');
        }
        return text;
      })().timeout(timeout);
    } on TimeoutException {
      pending?.abort();
      throw TimeoutException('DLNA $action 超时', timeout);
    }
  }

  static String _xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String _clock(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  static String _metadata(
    Uri media,
    String mime,
    String title,
    int? size,
    Duration? duration,
  ) =>
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1"><dc:title>${_xml(title)}</dc:title><upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="http-get:*:${_xml(mime)}:$_dlnaContentFeatures"${size == null ? '' : ' size="$size"'}${duration == null ? '' : ' duration="${_clock(duration)}"'}>${_xml(media.toString())}</res></item></DIDL-Lite>';

  void close() => _client.close(force: true);
}

class DlnaTransportInfo {
  const DlnaTransportInfo(this.state, this.status);
  final String state;
  final String status;
}

class DlnaPositionInfo {
  const DlnaPositionInfo({
    required this.trackUri,
    required this.position,
    this.duration,
  });
  final Uri? trackUri;
  final Duration? position;
  final Duration? duration;
}

Duration? _parseClock(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$').firstMatch(raw);
  if (match == null) return null;
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  if (minutes >= 60 || seconds >= 60) return null;
  return Duration(
    hours: int.parse(match.group(1)!),
    minutes: minutes,
    seconds: seconds,
  );
}

bool _isHlsMime(String mime) => const {
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
  'audio/mpegurl',
  'audio/x-mpegurl',
}.contains(mime.toLowerCase().split(';').first.trim());

const _dlnaContentFeatures =
    'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';

/// ConnectionManager Sink entries, without falling back to Source or arbitrary
/// XML text when a renderer omits Sink. Only HTTP GET resources are supported.
class DlnaProtocolInfo {
  const DlnaProtocolInfo(this.sink);
  final Set<String> sink;

  static DlnaProtocolInfo parse(String soapResponse) {
    final raw = soapResponse.contains('<')
        ? _xmlValue(soapResponse, 'Sink') ?? ''
        : soapResponse;
    final values = raw
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.split(':').length >= 4)
        .toSet();
    return DlnaProtocolInfo(values);
  }

  String? mimeFor(String mime) {
    final needle = mime.toLowerCase().split(';').first.trim();
    for (final value in sink) {
      final parts = value.split(':');
      if (parts.length < 4 || parts[0] != 'http-get') continue;
      final offered = parts[2].split(';').first.trim();
      if (offered == needle || (_isHlsMime(needle) && _isHlsMime(offered))) {
        return offered;
      }
      if (offered == '*') return needle;
    }
    return null;
  }

  bool supportsMime(String mime) => mimeFor(mime) != null;
}

/// Observable state for the in-app DLNA control surface.
class DlnaCastStatus {
  const DlnaCastStatus({
    this.session,
    this.device,
    this.transport,
    this.position,
    this.duration,
    this.volume,
    this.volumeSupported = false,
    this.seekSupported = true,
  });

  final CastSession? session;
  final CastDevice? device;
  final DlnaTransportInfo? transport;
  final Duration? position;
  final Duration? duration;
  final int? volume;
  final bool volumeSupported;
  final bool seekSupported;

  bool get active =>
      session != null &&
      session!.state != CastSessionState.failed &&
      session!.state != CastSessionState.stopped;

  bool get canSeek => controllable && seekSupported && position != null;

  bool get controllable =>
      session?.state == CastSessionState.playing ||
      session?.state == CastSessionState.paused;
}

/// Couples the protocol client to the Dart single-session state machine. The
/// caller supplies a public URL or a [MediaRelayServer.url] that was issued
/// for the selected task; the SOAP client never receives browser credentials.
class DlnaCastController extends ChangeNotifier {
  DlnaCastController(
    this.sessions, {
    this.onTemporaryTaskFinished,
    this.onSessionFinished,
    this.commandTimeout = const Duration(seconds: 5),
    this.confirmationTimeout = const Duration(seconds: 12),
    this.pollInterval = const Duration(milliseconds: 500),
    this.monitorInterval = const Duration(seconds: 2),
    this.relayTtl = const Duration(minutes: 5),
  });

  final CastSessionController sessions;
  final Future<void> Function(String taskId)? onTemporaryTaskFinished;
  final Future<void> Function(String taskId)? onSessionFinished;
  final Duration commandTimeout;
  final Duration confirmationTimeout;
  final Duration pollInterval;
  final Duration monitorInterval;
  final Duration relayTtl;
  DlnaSoapClient? _soap;
  MediaRelayServer? _relay;
  HlsRelayServer? _hlsRelay;
  Timer? _monitor;
  Timer? _expiry;
  int? _monitoringEpoch;
  Future<void> _commands = Future<void>.value();
  Future<CastSession>? _stopping;
  int _epoch = 0;
  CastDevice? _device;
  DlnaTransportInfo? _transport;
  Duration? _position;
  Duration? _duration;
  int? _volume;
  bool _volumeSupported = false;
  bool _seekSupported = true;
  Uri? _expectedUri;
  bool _disposed = false;

  CastSession? get active => sessions.active;

  void markTemporaryTask(String taskId) => _temporaryTaskIds.add(taskId);

  final _temporaryTaskIds = <String>{};

  DlnaCastStatus get status => DlnaCastStatus(
    session: active,
    device: _device,
    transport: _transport,
    position: _position,
    duration: _duration,
    volume: _volume,
    volumeSupported: _volumeSupported,
    seekSupported: _seekSupported,
  );

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  CastSession _transition(CastSessionState next, {String? errorCode}) {
    final previous = sessions.active;
    final value = sessions.transition(next, errorCode: errorCode);
    if ((next == CastSessionState.failed || next == CastSessionState.stopped) &&
        previous != null &&
        _temporaryTaskIds.remove(previous.mediaTaskId)) {
      final cleanup = onTemporaryTaskFinished;
      if (cleanup != null) unawaited(cleanup(previous.mediaTaskId));
    }
    _changed();
    return value;
  }

  void _resetControls() {
    _transport = null;
    _position = null;
    _duration = null;
    _volume = null;
    _volumeSupported = false;
    _seekSupported = true;
  }

  Future<CastSession> cast({
    required CastDevice device,
    required String mediaTaskId,
    required Uri mediaUrl,
    File? localFile,
    File? localHlsPlaylist,
    String mime = 'video/mp4',
    String title = 'Site Lens',
  }) async {
    if (_disposed) throw StateError('投屏控制器已关闭');
    if (_stopping != null) throw StateError('正在停止投屏，请稍后重试');
    if (sessions.tasks.isExclusive(mediaTaskId)) {
      throw StateError('媒体任务正在执行文件操作，请稍后重试');
    }
    if (localFile == null &&
        localHlsPlaylist == null &&
        (!const {'http', 'https'}.contains(mediaUrl.scheme) ||
            mediaUrl.host.isEmpty ||
            mediaUrl.userInfo.isNotEmpty)) {
      throw StateError('远程投屏媒体地址无效');
    }
    sessions.begin(device: device, mediaTaskId: mediaTaskId);
    final epoch = ++_epoch;
    _device = device;
    _resetControls();
    _changed();
    DlnaSoapClient? soap;
    MediaRelayServer? relay;
    HlsRelayServer? hlsRelay;
    try {
      _checkEpoch(epoch);
      _transition(CastSessionState.connecting);
      _checkEpoch(epoch);
      final profile = DlnaDiscovery.profileFor(device);
      soap = DlnaSoapClient(
        device.address,
        avTransportServiceType:
            profile?.avTransportServiceType ??
            'urn:schemas-upnp-org:service:AVTransport:1',
        connectionManagerControlUrl: profile?.connectionManagerControlUrl,
        connectionManagerServiceType: profile?.connectionManagerServiceType,
        renderingControlControlUrl: profile?.renderingControlControlUrl,
        renderingControlServiceType: profile?.renderingControlServiceType,
        timeout: commandTimeout,
      );
      _soap = soap;
      DlnaProtocolInfo? protocols;
      if (profile?.connectionManagerControlUrl != null) {
        protocols = await soap.protocolInfo();
        _checkEpoch(epoch);
      }
      final isHls = localHlsPlaylist != null || _isHlsMime(mime);
      final requestedMime = isHls ? 'application/vnd.apple.mpegurl' : mime;
      final negotiatedMime = protocols?.mimeFor(requestedMime);
      final supported = protocols == null
          ? (isHls ? device.supportsHls : device.supportsMp4)
          : negotiatedMime != null;
      if (!supported) {
        throw DlnaUnsupportedFormatException(
          mime: requestedMime,
          unknown: protocols == null && profile != null,
        );
      }
      mime = negotiatedMime ?? requestedMime;
      RelayAuthorization? authorization;
      int? size;
      if (localHlsPlaylist != null) {
        authorization = sessions.authorizeRelay(
          deviceId: device.id,
          ttl: relayTtl,
        );
        hlsRelay = await HlsRelayServer.start(
          authorization: authorization,
          playlist: localHlsPlaylist,
          allowedRoot: localHlsPlaylist.parent,
          receiver: device.address,
          mime: mime,
        );
        _checkEpoch(epoch);
        _hlsRelay = hlsRelay;
        mediaUrl = hlsRelay.url;
      } else if (localFile != null) {
        authorization = sessions.authorizeRelay(
          deviceId: device.id,
          ttl: relayTtl,
        );
        relay = await MediaRelayServer.start(
          authorization: authorization,
          file: localFile,
          allowedRoot: localFile.parent,
          receiver: device.address,
          mime: mime,
        );
        _checkEpoch(epoch);
        _relay = relay;
        mediaUrl = relay.url;
        size = await localFile.length();
      }
      _checkEpoch(epoch);
      _transition(CastSessionState.settingMedia);
      _checkEpoch(epoch);
      await soap.setMedia(mediaUrl, mime: mime, title: title, size: size);
      _checkEpoch(epoch);
      await soap.play();
      _checkEpoch(epoch);
      _expectedUri = mediaUrl;
      await _confirmPlayback(soap, mediaUrl, epoch);
      _checkEpoch(epoch);
      final result = _transition(CastSessionState.playing);
      _transport = const DlnaTransportInfo('PLAYING', 'OK');
      await _refreshPosition(soap, epoch, ignoreErrors: true);
      await _refreshVolume(soap, epoch);
      _checkEpoch(epoch);
      _changed();
      _monitor = Timer.periodic(monitorInterval, (_) {
        unawaited(_pollTransport(epoch));
      });
      if (authorization != null) {
        final remaining = authorization.expiresAt.difference(
          DateTime.now().toUtc(),
        );
        _expiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
          unawaited(_failActive(epoch, '投屏中继授权已过期，请重新投屏'));
        });
      }
      return result;
    } catch (error) {
      final reported = _normalizeCastError(error, mime);
      soap?.close();
      await relay?.close();
      await hlsRelay?.close();
      if (epoch == _epoch) {
        _epoch++;
        await _closeResources();
        _finish(CastSessionState.failed, errorCode: _castError(reported));
      }
      if (!identical(reported, error)) throw reported;
      rethrow;
    }
  }

  void _checkEpoch(int epoch) {
    if (epoch != _epoch) throw StateError('投屏已停止');
  }

  Future<void> _confirmPlayback(
    DlnaSoapClient soap,
    Uri expectedUri,
    int epoch,
  ) async {
    final deadline = DateTime.now().add(confirmationTimeout);
    var lastState = 'UNKNOWN';
    while (DateTime.now().isBefore(deadline)) {
      _checkEpoch(epoch);
      late final DlnaTransportInfo transport;
      try {
        transport = await soap.transportInfo().timeout(
          deadline.difference(DateTime.now()),
        );
      } on TimeoutException {
        break;
      }
      _checkEpoch(epoch);
      lastState = transport.state;
      if (transport.status != 'OK') {
        throw StateError('电视播放失败：${transport.status}（${transport.state}）');
      }
      if (transport.state == 'PLAYING') {
        DlnaPositionInfo? position;
        try {
          position = await soap.positionInfo().timeout(
            deadline.difference(DateTime.now()),
          );
        } on TimeoutException {
          break;
        } on DlnaSoapException catch (error) {
          if (!_isOptionalUnsupported(error)) rethrow;
        }
        _checkEpoch(epoch);
        _position = position?.position;
        _duration = position?.duration ?? _duration;
        _changed();
        var current = position?.trackUri;
        if (current == null || !current.hasScheme) {
          current = await soap.currentMedia().timeout(
            deadline.difference(DateTime.now()),
          );
          _checkEpoch(epoch);
        }
        if (current == expectedUri) return;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < pollInterval ? remaining : pollInterval,
      );
    }
    throw StateError('电视未确认开始播放（$lastState），请检查电视是否能访问手机的媒体中继');
  }

  Future<void> _pollTransport(int epoch) async {
    if (epoch != _epoch || _monitoringEpoch != null) return;
    _monitoringEpoch = epoch;
    try {
      await _enqueue(epoch, () => _readTransport(epoch));
    } catch (_) {
      // An explicit stop invalidates queued monitor work.
    } finally {
      if (_monitoringEpoch == epoch) _monitoringEpoch = null;
    }
  }

  Future<void> _readTransport(int epoch) async {
    final soap = _soap;
    if (soap == null) return;
    try {
      final transport = await soap.transportInfo();
      if (epoch != _epoch) return;
      _transport = transport;
      _changed();
      if (transport.status != 'OK') {
        await _failActive(epoch, '电视播放失败：${transport.status}');
      } else if (transport.state == 'STOPPED' ||
          transport.state == 'NO_MEDIA_PRESENT') {
        _epoch++;
        await _closeResources();
        _finish(CastSessionState.stopped);
        _resetControls();
        _changed();
      } else if (transport.state == 'PAUSED_PLAYBACK' &&
          sessions.active?.state == CastSessionState.playing) {
        _transition(CastSessionState.paused);
      } else if (transport.state == 'PLAYING' &&
          sessions.active?.state == CastSessionState.paused) {
        _transition(CastSessionState.playing);
      }
      if (epoch == _epoch &&
          transport.state != 'STOPPED' &&
          transport.state != 'NO_MEDIA_PRESENT') {
        await _refreshPosition(soap, epoch, ignoreErrors: true);
      }
    } catch (error) {
      await _failActive(epoch, _castError(error));
    }
  }

  Future<T> _enqueue<T>(int epoch, Future<T> Function() action) {
    final future = _commands.then((_) {
      _checkEpoch(epoch);
      return action();
    });
    _commands = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<void> _failActive(int epoch, String message) async {
    if (epoch != _epoch) return;
    _epoch++;
    await _closeResources();
    _finish(CastSessionState.failed, errorCode: message);
  }

  Future<void> _refreshPosition(
    DlnaSoapClient soap,
    int epoch, {
    required bool ignoreErrors,
  }) async {
    try {
      final position = await soap.positionInfo();
      if (epoch != _epoch) return;
      _position = position.position ?? _position;
      _duration = position.duration ?? _duration;
      _changed();
    } catch (_) {
      if (!ignoreErrors) rethrow;
    }
  }

  Future<void> _refreshVolume(DlnaSoapClient soap, int epoch) async {
    try {
      final volume = await soap.getVolume();
      if (epoch != _epoch) return;
      _volume = volume;
      _volumeSupported = volume != null;
      _changed();
    } on DlnaSoapException catch (error) {
      if (epoch != _epoch) return;
      if (_isOptionalUnsupported(error)) {
        _volume = null;
        _volumeSupported = false;
        _changed();
        return;
      }
      // Capability probing is optional after playback has been confirmed.
    } catch (_) {
      // A receiver may expose RenderingControl but reject GetVolume. Keep
      // playback alive and leave the volume control unavailable.
      if (epoch == _epoch) {
        _volume = null;
        _volumeSupported = false;
        _changed();
      }
    }
  }

  Future<CastSession> pause() => _enqueue(_epoch, _pause);

  Future<CastSession> _pause() async {
    final soap = _soap ?? (throw StateError('投屏会话不存在'));
    final epoch = _epoch;
    try {
      await soap.pause();
      _checkEpoch(epoch);
      final transport = await soap.transportInfo();
      if (transport.state != 'PAUSED_PLAYBACK' || transport.status != 'OK') {
        throw StateError('电视未确认暂停播放');
      }
      _checkEpoch(epoch);
      _transport = transport;
      final result = _transition(CastSessionState.paused);
      await _refreshPosition(soap, epoch, ignoreErrors: true);
      return result;
    } catch (error) {
      if (error is DlnaSoapException && _isOptionalUnsupported(error)) {
        throw DlnaOptionalCommandUnsupportedException(action: '暂停');
      }
      await _failActive(epoch, _castError(error));
      rethrow;
    }
  }

  Future<CastSession> resume() => _enqueue(_epoch, _resume);

  Future<CastSession> _resume() async {
    final soap = _soap ?? (throw StateError('投屏会话不存在'));
    final epoch = _epoch;
    try {
      final currentUri = await soap.currentMedia();
      if (currentUri == null || !currentUri.hasScheme) {
        throw StateError('电视没有可继续播放的媒体');
      }
      _checkEpoch(epoch);
      if (currentUri != _expectedUri) {
        throw StateError('电视已切换到其他媒体，请重新投屏');
      }
      await soap.play();
      _checkEpoch(epoch);
      await _confirmPlayback(soap, currentUri, epoch);
      _checkEpoch(epoch);
      final result = _transition(CastSessionState.playing);
      await _refreshPosition(soap, epoch, ignoreErrors: true);
      return result;
    } catch (error) {
      if (error is DlnaSoapException && _isOptionalUnsupported(error)) {
        throw DlnaOptionalCommandUnsupportedException(action: '继续播放');
      }
      await _failActive(epoch, _castError(error));
      rethrow;
    }
  }

  Future<CastSession> stop() {
    final pending = _stopping;
    if (pending != null) return pending;
    final stopping = _stop();
    _stopping = stopping;
    return stopping.whenComplete(() {
      if (identical(_stopping, stopping)) _stopping = null;
    });
  }

  Future<CastSession> _stop() async {
    _epoch++;
    final soap = _soap;
    Object? failure;
    try {
      if (soap != null) await soap.stop();
    } catch (error) {
      failure = error;
    } finally {
      await _closeResources();
    }
    if (failure != null) {
      _finish(CastSessionState.failed, errorCode: _castError(failure));
      throw failure;
    }
    _finish(CastSessionState.stopped);
    _resetControls();
    _changed();
    return sessions.active ?? (throw StateError('投屏会话不存在'));
  }

  Future<DlnaCastStatus> refresh() => _enqueue(_epoch, _refresh);

  Future<DlnaCastStatus> _refresh() async {
    final soap = _soap ?? (throw StateError('投屏会话不存在'));
    final epoch = _epoch;
    final transport = await soap.transportInfo();
    _checkEpoch(epoch);
    if (transport.status != 'OK') {
      await _failActive(epoch, '电视播放失败：${transport.status}');
      return status;
    }
    _transport = transport;
    if (transport.state == 'STOPPED' || transport.state == 'NO_MEDIA_PRESENT') {
      _epoch++;
      await _closeResources();
      _finish(CastSessionState.stopped);
      _resetControls();
      _changed();
      return status;
    }
    if (transport.state == 'PAUSED_PLAYBACK' &&
        sessions.active?.state == CastSessionState.playing) {
      _transition(CastSessionState.paused);
    } else if (transport.state == 'PLAYING' &&
        sessions.active?.state == CastSessionState.paused) {
      _transition(CastSessionState.playing);
    }
    await _refreshPosition(soap, epoch, ignoreErrors: true);
    await _refreshVolume(soap, epoch);
    _checkEpoch(epoch);
    return status;
  }

  Future<DlnaCastStatus> seek(Duration position) =>
      _enqueue(_epoch, () => _seek(position));

  Future<DlnaCastStatus> _seek(Duration position) async {
    final soap = _soap ?? (throw StateError('投屏会话不存在'));
    final epoch = _epoch;
    final duration = _duration;
    final bounded = duration == null || duration <= Duration.zero
        ? (position < Duration.zero ? Duration.zero : position)
        : _clampDuration(position, Duration.zero, duration);
    try {
      await soap.seek(bounded);
      _checkEpoch(epoch);
      _position = bounded;
      _changed();
      await _refreshPosition(soap, epoch, ignoreErrors: true);
      return status;
    } on DlnaSoapException catch (error) {
      if (_isOptionalUnsupported(error)) {
        if (epoch != _epoch) rethrow;
        _seekSupported = false;
        _changed();
        throw DlnaOptionalCommandUnsupportedException(
          action: '进度控制',
          message: '接收设备不支持拖动播放进度',
        );
      }
      await _failActive(epoch, _castError(error));
      rethrow;
    } catch (error) {
      await _failActive(epoch, _castError(error));
      rethrow;
    }
  }

  Future<DlnaCastStatus> seekBy(Duration offset) =>
      _enqueue(_epoch, () => _seek((_position ?? Duration.zero) + offset));

  Future<DlnaCastStatus> setVolume(int percent) =>
      _enqueue(_epoch, () => _setVolume(percent));

  Future<DlnaCastStatus> _setVolume(int percent) async {
    final soap = _soap ?? (throw StateError('投屏会话不存在'));
    final epoch = _epoch;
    try {
      await soap.setVolume(percent);
      _checkEpoch(epoch);
      _volume = percent.clamp(0, 100).toInt();
      _volumeSupported = true;
      _changed();
      return status;
    } on DlnaOptionalCommandUnsupportedException {
      rethrow;
    } on DlnaSoapException catch (error) {
      if (_isOptionalUnsupported(error)) {
        if (epoch != _epoch) rethrow;
        _volumeSupported = false;
        _volume = null;
        _changed();
        throw DlnaOptionalCommandUnsupportedException(
          action: '音量控制',
          message: '接收设备不支持音量控制',
        );
      }
      await _failActive(epoch, _castError(error));
      rethrow;
    } catch (error) {
      await _failActive(epoch, _castError(error));
      rethrow;
    }
  }

  Future<DlnaCastStatus> adjustVolume(int delta) => _enqueue(_epoch, () async {
    final current =
        _volume ??
        (throw DlnaOptionalCommandUnsupportedException(
          action: '音量控制',
          message: '当前设备未提供音量状态',
        ));
    return _setVolume(current + delta);
  });

  CastSession? _finish(CastSessionState next, {String? errorCode}) {
    final current = sessions.active;
    if (current == null ||
        current.state == CastSessionState.failed ||
        current.state == CastSessionState.stopped) {
      return current;
    }
    return _transition(next, errorCode: errorCode);
  }

  Future<void> _closeResources() async {
    _monitor?.cancel();
    _monitor = null;
    _expiry?.cancel();
    _expiry = null;
    final soap = _soap;
    final relay = _relay;
    final hlsRelay = _hlsRelay;
    _soap = null;
    _relay = null;
    _hlsRelay = null;
    soap?.close();
    await relay?.close();
    await hlsRelay?.close();
    final session = sessions.active;
    final cleanup = onSessionFinished;
    if (session != null &&
        session.state != CastSessionState.stopped &&
        session.state != CastSessionState.failed &&
        cleanup != null) {
      await cleanup(session.mediaTaskId);
    }
  }

  String _castError(Object error) {
    if (error is TimeoutException) return '电视响应超时，请检查连接后重新投屏';
    if (error is SocketException || error is HttpException) {
      return '投屏连接中断，请检查电视与手机的局域网连接';
    }
    return error is StateError ? error.message : '投屏失败，请检查接收设备';
  }

  bool _isOptionalUnsupported(DlnaSoapException error) => const {
    401,
    402,
    501,
    600,
    601,
    602,
    701,
    710,
    711,
  }.contains(error.upnpCode);

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    unawaited(_closeResources());
    _finish(CastSessionState.stopped);
    super.dispose();
  }

  Object _normalizeCastError(Object error, String mime) {
    if (error is DlnaSoapException &&
        (error.upnpCode == 704 || error.upnpCode == 714)) {
      return DlnaUnsupportedFormatException(mime: mime);
    }
    if (error is TimeoutException ||
        error is SocketException ||
        error is HttpException) {
      return StateError(_castError(error));
    }
    return error;
  }
}

Duration _clampDuration(Duration value, Duration minimum, Duration maximum) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}

/// Determines the local IPv4 address selected by the OS route to this receiver.
/// Interface enumeration order cannot distinguish Wi-Fi from VPN/mobile data.
class DlnaRelayRoute {
  static Future<String> forReceiver(
    Uri receiver, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final addresses = await InternetAddress.lookup(
      receiver.host,
      type: InternetAddressType.IPv4,
    ).timeout(timeout);
    Object? lastError;
    for (final address in addresses) {
      Socket? socket;
      try {
        final port = receiver.hasPort
            ? receiver.port
            : (receiver.scheme == 'https' ? 443 : 80);
        socket = await Socket.connect(address, port, timeout: timeout);
        return socket.address.address;
      } catch (error) {
        lastError = error;
      } finally {
        socket?.destroy();
      }
    }
    throw StateError(
      '无法确定通往接收设备的局域网地址${lastError is TimeoutException ? '，连接超时' : ''}',
    );
  }
}

/// Serves one authorized local file on the interface used to reach the TV.
class MediaRelayServer {
  MediaRelayServer._(
    this._server,
    this.authorization,
    this._file,
    this._host,
    this._mime,
  );

  final HttpServer _server;
  final RelayAuthorization authorization;
  final File _file;
  final String _host;
  final String _mime;
  Future<void>? _closing;

  Uri get url => Uri(
    scheme: 'http',
    host: _host,
    port: _server.port,
    path: '/media/${authorization.taskId}/video.mp4',
    queryParameters: {'token': authorization.token},
  );

  static Future<MediaRelayServer> start({
    required RelayAuthorization authorization,
    required File file,
    Directory? allowedRoot,
    String? advertisedHost,
    Uri? receiver,
    String mime = 'video/mp4',
  }) async {
    final root = (allowedRoot ?? file.parent).resolveSymbolicLinksSync();
    final canonical = file.resolveSymbolicLinksSync();
    if (!canonical.startsWith('$root${Platform.pathSeparator}') ||
        !await file.exists() ||
        await file.length() <= 0) {
      throw StateError('投屏媒体不存在、为空或超出授权目录');
    }
    final host = advertisedHost ?? await _relayHost(receiver);
    final server = await HttpServer.bind(InternetAddress(host), 0);
    final relay = MediaRelayServer._(
      server,
      authorization,
      File(canonical),
      host,
      mime,
    );
    server.listen(relay._handle);
    return relay;
  }

  Future<void> _handle(HttpRequest request) async {
    if (!_authorizedRequest(request, authorization) ||
        request.uri.path != url.path) {
      await _closeResponse(request.response, HttpStatus.forbidden);
      return;
    }
    try {
      await _serveFile(request, _file, _mime);
    } catch (_) {
      await _closeResponse(request.response, HttpStatus.internalServerError);
    }
  }

  Future<void> close() =>
      _closing ??= _server.close(force: true).then<void>((_) {});
}

Future<String> _relayHost(Uri? receiver) {
  if (receiver == null) {
    throw StateError('投屏中继需要指定接收设备的局域网地址');
  }
  return DlnaRelayRoute.forReceiver(receiver);
}

bool _authorizedRequest(
  HttpRequest request,
  RelayAuthorization authorization,
) =>
    (request.method == 'GET' || request.method == 'HEAD') &&
    request.uri.queryParameters['token'] == authorization.token &&
    !authorization.expired;

void _setDlnaHeaders(HttpRequest request, String mime, int length) {
  final response = request.response;
  response.headers.contentType = ContentType.parse(mime);
  response.contentLength = length;
  response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  response.headers.set('contentFeatures.dlna.org', _dlnaContentFeatures);
  final mode = request.headers.value('transferMode.dlna.org');
  response.headers.set(
    'transferMode.dlna.org',
    const {'Streaming', 'Interactive', 'Background'}.contains(mode)
        ? mode!
        : 'Streaming',
  );
  response.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
}

Future<void> _closeResponse(HttpResponse response, int status) async {
  try {
    response.statusCode = status;
    await response.close();
  } catch (_) {
    // The renderer can close its probe/seek request before the body is sent.
  }
}

({int start, int end})? _byteRange(String? raw, int length) {
  if (raw == null || raw.isEmpty) return null;
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(raw.trim());
  if (match == null || length <= 0) throw const FormatException('Range 无效');
  final first = match.group(1)!;
  final last = match.group(2)!;
  if (first.isEmpty) {
    final suffix = int.tryParse(last);
    if (suffix == null || suffix <= 0) throw const FormatException('Range 无效');
    return (start: suffix >= length ? 0 : length - suffix, end: length - 1);
  }
  final start = int.tryParse(first);
  final requestedEnd = last.isEmpty ? length - 1 : int.tryParse(last);
  if (start == null ||
      requestedEnd == null ||
      start >= length ||
      requestedEnd < start) {
    throw const FormatException('Range 越界');
  }
  return (
    start: start,
    end: requestedEnd >= length ? length - 1 : requestedEnd,
  );
}

Future<void> _serveFile(HttpRequest request, File file, String mime) async {
  final length = await file.length();
  ({int start, int end})? range;
  try {
    // HTTP Range is defined for GET; HEAD reports the complete representation.
    range = _byteRange(
      request.method == 'GET' ? request.headers.value('range') : null,
      length,
    );
  } on FormatException {
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes */$length',
    );
    await _closeResponse(
      request.response,
      HttpStatus.requestedRangeNotSatisfiable,
    );
    return;
  }
  final start = range?.start ?? 0;
  final end = range?.end ?? length - 1;
  _setDlnaHeaders(request, mime, length == 0 ? 0 : end - start + 1);
  if (range != null) {
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/$length',
    );
  }
  if (request.method == 'HEAD' || length == 0) {
    await request.response.close();
    return;
  }
  await file.openRead(start, end + 1).pipe(request.response);
}

/// Rewrites only the approved manifest tree. A token never authorizes arbitrary
/// files elsewhere in the cache, even if they happen to share its directory.
class HlsRelayServer {
  HlsRelayServer._(
    this._server,
    this.authorization,
    this._root,
    this._playlist,
    this._host,
    this._mime,
  ) : _allowedFiles = {_playlist};

  final HttpServer _server;
  final RelayAuthorization authorization;
  final String _root;
  final String _playlist;
  final String _host;
  final String _mime;
  final Set<String> _allowedFiles;
  Future<void>? _closing;

  Uri get url => _urlFor(_playlist);

  Uri _urlFor(String canonical) => Uri(
    scheme: 'http',
    host: _host,
    port: _server.port,
    path:
        '/hls/${authorization.taskId}/${canonical.substring(_root.length + 1).replaceAll(Platform.pathSeparator, '/')}',
    queryParameters: {'token': authorization.token},
  );

  static Future<HlsRelayServer> start({
    required RelayAuthorization authorization,
    required File playlist,
    Directory? allowedRoot,
    String? advertisedHost,
    Uri? receiver,
    String mime = 'application/vnd.apple.mpegurl',
  }) async {
    final root = (allowedRoot ?? playlist.parent).resolveSymbolicLinksSync();
    final canonicalPlaylist = playlist.resolveSymbolicLinksSync();
    if (!canonicalPlaylist.startsWith('$root${Platform.pathSeparator}') ||
        !await playlist.exists()) {
      throw StateError('HLS 清单不存在或超出授权目录');
    }
    final host = advertisedHost ?? await _relayHost(receiver);
    final server = await HttpServer.bind(InternetAddress(host), 0);
    final relay = HlsRelayServer._(
      server,
      authorization,
      root,
      canonicalPlaylist,
      host,
      mime,
    );
    server.listen(relay._handle);
    return relay;
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (!_authorizedRequest(request, authorization) ||
        segments.length < 3 ||
        segments[0] != 'hls' ||
        segments[1] != authorization.taskId ||
        segments
            .skip(2)
            .any(
              (value) =>
                  value == '..' || value.contains('/') || value.contains('\\'),
            )) {
      await _closeResponse(request.response, HttpStatus.forbidden);
      return;
    }
    try {
      final file = File('$_root/${segments.skip(2).join('/')}');
      final canonical = file.resolveSymbolicLinksSync();
      if (!canonical.startsWith('$_root${Platform.pathSeparator}') ||
          !_allowedFiles.contains(canonical)) {
        await _closeResponse(request.response, HttpStatus.forbidden);
        return;
      }
      if (canonical.toLowerCase().endsWith('.m3u8') ||
          canonical.toLowerCase().endsWith('.m3u')) {
        final rewritten = _rewrite(await file.readAsString(), file.parent);
        final bytes = utf8.encode(rewritten);
        _setDlnaHeaders(request, _mime, bytes.length);
        if (request.method == 'GET') request.response.add(bytes);
        await request.response.close();
      } else {
        await _serveFile(request, file, _contentType(canonical));
      }
    } catch (_) {
      await _closeResponse(request.response, HttpStatus.forbidden);
    }
  }

  String _rewrite(String source, Directory base) => source
      .split(RegExp(r'\r?\n'))
      .map((line) {
        if (line.trim().startsWith('#')) {
          return line.replaceAllMapped(
            RegExp(r'\bURI="([^"]+)"'),
            (match) => 'URI="${_relativeUri(base, match.group(1)!)}"',
          );
        }
        if (line.trim().isEmpty) return line;
        return _relativeUri(base, line.trim());
      })
      .join('\n');

  String _relativeUri(Directory base, String raw) {
    final parsed = Uri.tryParse(raw);
    if (parsed == null ||
        parsed.hasScheme ||
        parsed.hasAuthority ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        raw.startsWith('/')) {
      throw StateError('HLS 中继仅支持已缓存的本地资源');
    }
    final file = File.fromUri(base.uri.resolveUri(parsed));
    final canonical = file.resolveSymbolicLinksSync();
    if (!canonical.startsWith('$_root${Platform.pathSeparator}') ||
        !file.existsSync()) {
      throw StateError('HLS 中继资源缺失或超出授权目录');
    }
    _allowedFiles.add(canonical);
    final url = _urlFor(canonical);
    return '${url.path}?${url.query}';
  }

  String _contentType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.ts')) return 'video/mp2t';
    if (lower.endsWith('.m4s')) return 'video/iso.segment';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    return 'application/octet-stream';
  }

  Future<void> close() =>
      _closing ??= _server.close(force: true).then<void>((_) {});
}
