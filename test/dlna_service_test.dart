import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/dlna_service.dart';
import 'package:site_lens/media/media_service.dart';

void main() {
  _httpTests();
  test(
    'device description resolves URLBase and selects AVTransport services',
    () {
      final description = DlnaDiscovery.parseDescription(
        '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://tv.example:8080/upnp/</URLBase>
  <device><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>cm/control</controlURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/av/control</controlURL></service>
  </serviceList></device>
</root>''',
        Uri.parse('http://tv.example:8080/description.xml'),
      );

      expect(description, isNotNull);
      expect(
        description!.avTransportControlUrl,
        Uri.parse('http://tv.example:8080/av/control'),
      );
      expect(
        description.connectionManagerControlUrl,
        Uri.parse('http://tv.example:8080/upnp/cm/control'),
      );
    },
  );

  test('protocol info accepts only renderer sink MIME entries', () {
    final info = DlnaProtocolInfo.parse(
      '<Sink>http-get:*:video/mp4:*,http-get:*:application/vnd.apple.mpegurl:*</Sink>',
    );
    expect(info.mimeFor('video/mp4'), 'video/mp4');
    expect(info.mimeFor('application/vnd.apple.mpegurl'), isNotNull);
    expect(info.mimeFor('audio/flac'), isNull);
  });

  test('failed cast releases the task and allows a new session', () {
    final tasks = MediaTaskStore();
    final task = tasks.create(
      MediaCandidate(
        id: 'cast-candidate',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.com/watch'),
        mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
        title: '示例',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
      ),
    );
    final device = CastDevice(
      id: 'tv',
      name: '电视',
      address: Uri.parse('http://192.0.2.10:1400/av/control'),
      supportsMp4: true,
    );
    final sessions = CastSessionController(tasks: tasks);
    sessions.begin(device: device, mediaTaskId: task.id);
    sessions.transition(CastSessionState.connecting);
    sessions.transition(CastSessionState.failed, errorCode: 'timeout');
    expect(tasks.canDelete(task.id), isTrue);

    expect(
      sessions.begin(device: device, mediaTaskId: task.id).state,
      CastSessionState.discovering,
    );
  });

  test('unsupported HLS error gives a recovery instruction', () {
    final error = DlnaUnsupportedFormatException(
      mime: 'application/vnd.apple.mpegurl',
    );
    expect(error.code, MediaErrorCode.unsupported);
    expect(error.requiresMp4, isTrue);
    expect(error.message, contains('先转为 MP4'));
  });
}

void _httpTests() {
  group('DLNA HTTP receiver', () {
    late _Receiver receiver;
    late Directory root;
    late File file;
    late MediaTaskStore tasks;
    late MediaTask task;
    late CastDevice device;
    late DlnaCastController cast;

    Future<CastSession> start({File? playlist}) => cast.cast(
      device: device,
      mediaTaskId: task.id,
      mediaUrl: (playlist ?? file).uri,
      localFile: playlist == null ? file : null,
      localHlsPlaylist: playlist,
      title: '中文 <TV> & "title"',
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dlna-http-test-');
      file = File('${root.path}/video.mp4')
        ..writeAsBytesSync(List.generate(32, (index) => index));
      receiver = await _Receiver.start();
      tasks = MediaTaskStore();
      task = tasks.create(
        MediaCandidate(
          id: 'media',
          hostId: 1,
          generation: 1,
          sourceUrl: Uri.parse('https://example.com/watch'),
          mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
          title: 'media',
          mime: 'video/mp4',
          source: MediaCandidateSource.dom,
        ),
      );
      device = (await const DlnaDiscovery().readDevice(
        receiver.descriptionUrl,
      ))!;
      cast = DlnaCastController(
        CastSessionController(tasks: tasks),
        commandTimeout: const Duration(milliseconds: 250),
        confirmationTimeout: const Duration(milliseconds: 120),
        pollInterval: const Duration(milliseconds: 5),
        monitorInterval: const Duration(hours: 1),
      );
    });

    tearDown(() async {
      try {
        await cast.stop();
      } catch (_) {}
      await receiver.close();
      await root.delete(recursive: true);
    });

    test(
      'discovers ConnectionManager endpoint and HLS aliases from Sink only',
      () async {
        expect(device.supportsMp4, isTrue);
        expect(device.supportsHls, isFalse);
        expect(receiver.paths['GetProtocolInfo'], '/cm');
        expect(receiver.bodies['GetProtocolInfo'], isNot(contains('<Source>')));
        receiver.sink = 'http-get:*:application/x-mpegurl:*';
        final hlsDevice = (await const DlnaDiscovery().readDevice(
          receiver.descriptionUrl,
        ))!;
        expect(hlsDevice.supportsHls, isTrue);
        expect(
          DlnaProtocolInfo.parse(
            '<Source>http-get:*:application/x-mpegurl:*</Source>',
          ).supportsMime('application/x-mpegurl'),
          isFalse,
        );
        expect(
          DlnaProtocolInfo.parse('rtsp-rtp-udp:*:application/x-mpegurl:*')
              .supportsMime('application/x-mpegurl'),
          isFalse,
        );
      },
    );

    test(
      'confirms PLAYING, expected URI and position using advertised version',
      () async {
        receiver.transitioningQueries = 2;
        final session = await start();
        expect(session.state, CastSessionState.playing);
        expect(receiver.actions, contains('GetPositionInfo'));
        expect(receiver.transportQueries, greaterThanOrEqualTo(3));
        expect(receiver.soapActions['Play'], contains('AVTransport:2#Play'));
        final body = receiver.bodies['SetAVTransportURI']!;
        expect(
          receiver.contentLengths['SetAVTransportURI'],
          utf8.encode(body).length,
        );
        final metadata = _xmlText(body, 'CurrentURIMetaData');
        expect(metadata, contains('size="32"'));
        expect(metadata, contains('DLNA.ORG_OP=01'));
        expect(metadata, contains('中文 &lt;TV&gt; &amp; &quot;title&quot;'));
        expect(receiver.media!.host, '127.0.0.1');
        expect(tasks.canDelete(task.id), isFalse);
        await cast.stop();
        expect(tasks.canDelete(task.id), isTrue);
        await _expectClosed(receiver.media!);
      },
    );

    test('SOAP acceptance while STOPPED fails and closes the relay', () async {
      receiver.state = 'STOPPED';
      await expectLater(start(), throwsStateError);
      expect(cast.active!.state, CastSessionState.failed);
      expect(cast.active!.errorCode, contains('未确认'));
      expect(tasks.canDelete(task.id), isTrue);
      await _expectClosed(receiver.media!);
    });

    test('PLAYING for another URI cannot confirm casting', () async {
      receiver.trackOverride = 'http://example.com/previous.mp4';
      await expectLater(start(), throwsStateError);
      expect(cast.active!.state, CastSessionState.failed);
      expect(tasks.canDelete(task.id), isTrue);
      await _expectClosed(receiver.media!);
    });

    test(
      'HLS rejection guides conversion and failed session can retry MP4',
      () async {
        final playlist = File('${root.path}/index.m3u8')
          ..writeAsStringSync('#EXTM3U\n');
        await expectLater(
          start(playlist: playlist),
          throwsA(
            isA<DlnaUnsupportedFormatException>()
                .having((error) => error.requiresMp4, 'requiresMp4', isTrue)
                .having((error) => error.message, 'guidance', contains('MP4')),
          ),
        );
        expect(tasks.canDelete(task.id), isTrue);
        expect(receiver.actions, isNot(contains('SetAVTransportURI')));
        await start();
        expect(cast.active!.state, CastSessionState.playing);
      },
    );

    test(
      'SOAP MIME fault with any prefix gives HLS conversion guidance',
      () async {
        receiver.sink = 'http-get:*:application/x-mpegurl:*';
        receiver.faultAction = 'Play';
        receiver.faultCode = 714;
        final playlist = File('${root.path}/index.m3u8')
          ..writeAsStringSync('#EXTM3U\n');
        await expectLater(
          start(playlist: playlist),
          throwsA(
            isA<DlnaUnsupportedFormatException>().having(
              (e) => e.requiresMp4,
              'requiresMp4',
              isTrue,
            ),
          ),
        );
        expect(tasks.canDelete(task.id), isTrue);
        await _expectClosed(receiver.media!);
      },
    );

    test(
      'command timeout and Stop fault always release relay and task',
      () async {
        receiver.hangAction = 'Play';
        await expectLater(
          start(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('电视响应超时'),
            ),
          ),
        );
        expect(cast.active!.state, CastSessionState.failed);
        expect(tasks.canDelete(task.id), isTrue);
        await _expectClosed(receiver.media!);
        receiver.hangAction = null;
        await start();
        receiver.faultAction = 'Stop';
        await expectLater(cast.stop(), throwsA(isA<DlnaSoapException>()));
        expect(cast.active!.state, CastSessionState.failed);
        expect(tasks.canDelete(task.id), isTrue);
        await _expectClosed(receiver.media!);
      },
    );

    test(
      'stopping during startup cancels pending cast and releases task',
      () async {
        receiver.hangAction = 'Play';
        final pending = expectLater(start(), throwsA(anything));
        await _eventually(() => receiver.actions.contains('Play'));
        await cast.stop();
        await pending;
        expect(cast.active!.state, CastSessionState.stopped);
        expect(tasks.canDelete(task.id), isTrue);
        await _expectClosed(receiver.media!);
      },
    );

    test(
      'remote error and authorization expiry clean established sessions',
      () async {
        cast = DlnaCastController(
          CastSessionController(tasks: tasks),
          monitorInterval: const Duration(milliseconds: 15),
          relayTtl: const Duration(milliseconds: 250),
        );
        await start();
        receiver.status = 'ERROR_OCCURRED';
        await _eventually(() => cast.active!.state == CastSessionState.failed);
        expect(tasks.canDelete(task.id), isTrue);
        receiver.status = 'OK';
        await start();
        await _eventually(() => cast.active!.state == CastSessionState.failed);
        expect(cast.active!.errorCode, contains('过期'));
        expect(tasks.canDelete(task.id), isTrue);
        await _expectClosed(receiver.media!);
      },
    );

    test(
      'relay HEAD, suffix/open ranges, DLNA headers and unauthorized requests',
      () async {
        final relay = await MediaRelayServer.start(
          authorization: const RelayAuthorizer().issue(
            sessionId: 's',
            taskId: 't',
            deviceId: 'd',
          ),
          file: file,
          receiver: device.address,
        );
        addTearDown(relay.close);
        final head = await _get(relay.url, method: 'HEAD');
        expect(head.status, 200);
        expect(head.bytes, isEmpty);
        expect(head.headers['content-length'], '32');
        expect(
          head.headers['contentfeatures.dlna.org'],
          contains('DLNA.ORG_OP=01'),
        );
        expect(head.headers['transfermode.dlna.org'], 'Streaming');
        final suffix = await _get(relay.url, range: 'bytes=-4');
        expect(suffix.status, 206);
        expect(suffix.bytes, [28, 29, 30, 31]);
        expect(suffix.headers['content-range'], 'bytes 28-31/32');
        expect((await _get(relay.url, range: 'bytes=30-')).bytes, [30, 31]);
        expect((await _get(relay.url, range: 'bytes=999-')).status, 416);
        expect(
          (await _get(relay.url.replace(query: 'token=wrong'))).status,
          403,
        );
        expect((await _get(relay.url, method: 'POST')).status, 403);
      },
    );

    test(
      'HLS rewrites selected manifest and nested keys/segments with ranges',
      () async {
        final master = File('${root.path}/master.m3u8')
          ..writeAsStringSync(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvariant.m3u8\n',
          );
        File('${root.path}/variant.m3u8').writeAsStringSync(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.key"\n#EXTINF:1,\nseg.ts\n',
        );
        File('${root.path}/key.key').writeAsBytesSync([5, 6]);
        File('${root.path}/seg.ts').writeAsBytesSync([1, 2, 3, 4]);
        File('${root.path}/secret.json').writeAsStringSync('not authorized');
        final relay = await HlsRelayServer.start(
          authorization: const RelayAuthorizer().issue(
            sessionId: 's',
            taskId: 't',
            deviceId: 'd',
          ),
          playlist: master,
          receiver: device.address,
          mime: 'application/x-mpegurl',
        );
        addTearDown(relay.close);
        final response = await _get(relay.url);
        expect(
          response.headers['content-type'],
          startsWith('application/x-mpegurl'),
        );
        final path = utf8
            .decode(response.bytes)
            .split('\n')
            .firstWhere((line) => line.startsWith('/hls/'));
        final variant = await _get(relay.url.resolve(path));
        final text = utf8.decode(variant.bytes);
        expect(text, contains('URI="/hls/t/key.key?token='));
        final segment = text
            .split('\n')
            .firstWhere((line) => line.startsWith('/hls/'));
        final ranged = await _get(
          relay.url.resolve(segment),
          range: 'bytes=1-2',
        );
        expect(ranged.status, 206);
        expect(ranged.bytes, [2, 3]);
        expect(
          (await _get(relay.url.replace(path: '/hls/t/secret.json'))).status,
          403,
        );
      },
    );
  });
}

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _xmlText(String source, String tag) {
  final text =
      RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(source)?.group(1) ??
      '';
  return text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&');
}

class _Receiver {
  _Receiver(this.server);
  final HttpServer server;
  final actions = <String>[];
  final bodies = <String, String>{};
  final paths = <String, String>{};
  final soapActions = <String, String>{};
  final contentLengths = <String, int>{};
  String sink = 'http-get:*:video/mp4:*';
  String state = 'PLAYING';
  String status = 'OK';
  String? faultAction;
  int faultCode = 701;
  String? hangAction;
  String? trackOverride;
  Uri? media;
  int transportQueries = 0;
  int transitioningQueries = 0;

  Uri get descriptionUrl =>
      Uri.parse('http://127.0.0.1:${server.port}/device.xml');
  static Future<_Receiver> start() async {
    final receiver = _Receiver(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    receiver.server.listen((request) {
      unawaited(receiver._handle(request));
    });
    return receiver;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET') {
        request.response.write(
          '<root><URLBase>${descriptionUrl.resolve('/base/')}</URLBase><friendlyName>TV &amp; Box</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType><controlURL>av</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/cm</controlURL></service></serviceList></root>',
        );
        await request.response.close();
        return;
      }
      final actionHeader = request.headers.value('soapaction') ?? '';
      final action = actionHeader.split('#').last.replaceAll('"', '');
      final body = await utf8.decoder.bind(request.cast<List<int>>()).join();
      actions.add(action);
      bodies[action] = body;
      paths[action] = request.uri.path;
      soapActions[action] = actionHeader;
      contentLengths[action] = request.contentLength;
      if (action == 'SetAVTransportURI') {
        media = Uri.parse(_xmlText(body, 'CurrentURI'));
      }
      if (action == hangAction) return;
      if (action == faultAction) {
        request.response.statusCode = 500;
        request.response.write(
          '<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/"><env:Body><env:Fault><detail><UPnPError><errorCode>$faultCode</errorCode><errorDescription>Illegal MIME-type</errorDescription></UPnPError></detail></env:Fault></env:Body></env:Envelope>',
        );
      } else {
        var output = '';
        switch (action) {
          case 'GetProtocolInfo':
            output =
                '<Source>http-get:*:application/vnd.apple.mpegurl:*</Source><Sink>$sink</Sink>';
          case 'GetTransportInfo':
            transportQueries++;
            output =
                '<CurrentTransportState>${transportQueries <= transitioningQueries ? 'TRANSITIONING' : state}</CurrentTransportState><CurrentTransportStatus>$status</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>';
          case 'GetPositionInfo':
            output =
                '<TrackURI>${_escape(trackOverride ?? media?.toString() ?? '')}</TrackURI><RelTime>00:00:01</RelTime>';
          case 'GetMediaInfo':
            output =
                '<CurrentURI>${_escape(media?.toString() ?? '')}</CurrentURI>';
        }
        request.response.write(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:2">$output</u:${action}Response></s:Body></s:Envelope>',
        );
      }
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() => server.close(force: true).then<void>((_) {});
}

Future<({int status, Map<String, String> headers, List<int> bytes})> _get(
  Uri uri, {
  String method = 'GET',
  String? range,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 250);
  try {
    final request = await client.openUrl(method, uri);
    if (range != null) request.headers.set('range', range);
    request.headers.set('getcontentFeatures.dlna.org', '1');
    final response = await request.close();
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    return (status: response.statusCode, headers: headers, bytes: bytes);
  } finally {
    client.close(force: true);
  }
}

Future<void> _expectClosed(Uri uri) =>
    expectLater(_get(uri), throwsA(isA<SocketException>()));

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}
