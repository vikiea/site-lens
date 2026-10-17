import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/models.dart';
import 'media_service.dart';

/// Minimal SSDP/AVTransport implementation for a single user-selected DLNA
/// session. Discovery and SOAP are intentionally separate from the relay so a
/// device can be used with a public MP4 URL without opening a server.
class DlnaDiscovery {
  const DlnaDiscovery({this.timeout = const Duration(seconds: 2)});
  final Duration timeout;

  Future<List<CastDevice>> discover() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final request = utf8.encode(
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 1\r\n'
      'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n',
    );
    final byLocation = <String, _SsdpResponse>{};
    final completer = Completer<void>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final response = _SsdpResponse.parse(
        utf8.decode(datagram.data, allowMalformed: true),
      );
      if (response.location != null) byLocation[response.location!] = response;
    });
    socket.send(request, InternetAddress('239.255.255.250'), 1900);
    await completer.future;
    timer.cancel();
    socket.close();
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
    if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return null;
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final body = await (await request.close())
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final friendly = _xmlTag(body, 'friendlyName') ?? uri.host;
      final model = _xmlTag(body, 'modelName');
      final control = _controlUrl(body, uri);
      if (control == null) return null;
      final id = sha256
          .convert(utf8.encode(control.toString()))
          .toString()
          .substring(0, 24);
      return CastDevice(
        id: id,
        name: friendly,
        address: control,
        model: model,
        supportsMp4: true,
        supportsHls: false,
        supportsSeek: true,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String? _xmlTag(String source, String name) => RegExp(
    '<(?:[A-Za-z0-9_.-]+:)?$name[^>]*>([^<]*)<',
    caseSensitive: false,
  ).firstMatch(source)?.group(1)?.trim();

  Uri? _controlUrl(String source, Uri base) {
    final matches =
        RegExp(
              r'<(?:[A-Za-z0-9_.-]+:)?service[^>]*>.*?<controlURL>([^<]+)</controlURL>.*?</(?:[A-Za-z0-9_.-]+:)?service>',
              caseSensitive: false,
              dotAll: true,
            )
            .allMatches(source)
            .where(
              (match) =>
                  (match.group(0) ?? '').toLowerCase().contains('avtransport'),
            );
    final service = matches.isEmpty ? null : matches.first;
    if (service == null) return null;
    final raw = service.group(1);
    return raw == null ? null : base.resolve(raw.trim());
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

class DlnaSoapClient {
  DlnaSoapClient(this.controlUrl, {HttpClient? client})
    : _client = client ?? HttpClient();
  final Uri controlUrl;
  final HttpClient _client;

  Future<void> setMedia(
    Uri mediaUrl, {
    String mime = 'video/mp4',
    String title = 'Site Lens',
  }) => _action(
    'SetAVTransportURI',
    '<InstanceID>0</InstanceID><CurrentURI>${_xml(mediaUrl.toString())}</CurrentURI><CurrentURIMetaData>${_xml(_metadata(mediaUrl, mime, title))}</CurrentURIMetaData>',
  );
  Future<void> play() =>
      _action('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  Future<void> pause() => _action('Pause', '<InstanceID>0</InstanceID>');
  Future<void> stop() => _action('Stop', '<InstanceID>0</InstanceID>');
  Future<void> seek(Duration position) => _action(
    'Seek',
    '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${_clock(position)}</Target>',
  );

  Future<void> _action(String action, String arguments) async {
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$arguments</u:$action></s:Body></s:Envelope>';
    final request = await _client.postUrl(controlUrl);
    request.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    request.headers.set(
      'SOAPACTION',
      '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
    );
    request.write(body);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        text.contains('<s:Fault')) {
      throw StateError('DLNA SOAP $action failed (${response.statusCode})');
    }
  }

  static String _xml(String value) => const HtmlEscape().convert(value);
  static String _clock(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  static String _metadata(Uri media, String mime, String title) =>
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1"><dc:title>${_xml(title)}</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:$mime:*">${_xml(media.toString())}</res></item></DIDL-Lite>';

  void close() => _client.close(force: true);
}

/// Short-lived local relay for a previously authorized media task. Requests
/// require the exact session/device/task token and can only read the supplied
/// app-private file. It implements HEAD and byte ranges for TV clients.
class MediaRelayServer {
  MediaRelayServer._(
    this._server,
    this.authorization,
    this._file,
    this._advertisedHost,
  );
  final HttpServer _server;
  final RelayAuthorization authorization;
  final File _file;
  final String _advertisedHost;

  Uri get url => Uri.parse(
    'http://$_advertisedHost:${_server.port}/media/${authorization.taskId}?token=${authorization.token}',
  );

  static Future<MediaRelayServer> start({
    required RelayAuthorization authorization,
    required File file,
    Directory? allowedRoot,
    String? advertisedHost,
  }) async {
    final root = (allowedRoot ?? file.parent).absolute;
    final canonical = file.resolveSymbolicLinksSync();
    final rootPath = root.resolveSymbolicLinksSync();
    if (!(canonical == rootPath ||
        canonical.startsWith('$rootPath${Platform.pathSeparator}'))) {
      throw StateError(MediaErrorCode.relayDenied);
    }
    if (!await file.exists()) throw StateError(MediaErrorCode.relayDenied);
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final host = advertisedHost ?? await _routableHost();
    final relay = MediaRelayServer._(server, authorization, file, host);
    server.listen(relay._handle);
    return relay;
  }

  static Future<String> _routableHost() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback && address.address.isNotEmpty) {
          return address.address;
        }
      }
    }
    throw StateError('没有可用于 DLNA 中继的局域网地址');
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      const validator = RelayRequestValidator();
      final range = validator.validate(
        RelayRequest(
          method: request.method,
          range: request.headers.value('range'),
        ),
      );
      final token = request.uri.queryParameters['token'];
      if (token == null ||
          token != authorization.token ||
          authorization.expired ||
          request.uri.pathSegments.length != 2 ||
          request.uri.pathSegments[1] != authorization.taskId) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final length = await _file.length();
      final start = range.start ?? 0;
      final end = (range.end ?? length - 1).clamp(0, length - 1);
      if (start >= length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$length',
        );
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.contentLength = end - start + 1;
      if (range.start != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        );
      }
      if (request.method == 'HEAD') {
        await request.response.close();
        return;
      }
      await _file.openRead(start, end + 1).pipe(request.response);
    } catch (_) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}
