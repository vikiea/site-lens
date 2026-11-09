import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/discovery/probe_coordinator.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  for (final download in [false, true]) {
    test(
      'request timeout leaves the caller token reusable: file=$download',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final directory = await Directory.systemTemp.createTemp(
          'request-timeout-',
        );
        server.listen((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          request.response.write('complete');
          await request.response.close();
        });
        final url = Uri.parse('http://127.0.0.1:${server.port}/');
        final cancel = Cancellation();
        final http = ControlledHttp(allowLocal: true);
        try {
          if (download) {
            await expectLater(
              http.fetchToFile(
                url,
                connect: const {'*'},
                document: url,
                cancel: cancel,
                destination: File('${directory.path}/download.part'),
                timeout: const Duration(milliseconds: 20),
              ),
              throwsA(isA<TimeoutException>()),
            );
          } else {
            await expectLater(
              http.fetch(
                url,
                connect: const {'*'},
                document: url,
                cancel: cancel,
                timeout: const Duration(milliseconds: 20),
              ),
              throwsA(isA<TimeoutException>()),
            );
          }
          expect(cancel.cancelled, isFalse);
          await http.fetch(
            url,
            connect: const {'*'},
            document: url,
            cancel: cancel,
            timeout: const Duration(seconds: 2),
          );
        } finally {
          cancel.cancel();
          await server.close(force: true);
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test('one failed candidate does not block other discovery results', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write('ready');
      await request.response.close();
    });
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = dead.port;
    await dead.close();
    final saved = <ProbeResult>[];
    final coordinator = ProbeCoordinator(
      candidates: () async => [
        Candidate(
          id: 1,
          url: Uri.parse('http://127.0.0.1:$deadPort/closed'),
          label: 'closed',
        ),
        Candidate(
          id: 2,
          url: Uri.parse('http://127.0.0.1:${server.port}/ready'),
          label: 'ready',
        ),
      ],
      httpProbe: HttpProbe(allowLocal: true),
      verifier: _ReadyVerifier(),
      save: (result) async => saved.add(result),
    );
    try {
      await coordinator.run();
      expect(coordinator.running, isFalse);
      expect(coordinator.results[1]?.status, ProbeStatus.offline);
      expect(coordinator.results[2]?.status, ProbeStatus.ready);
      expect(coordinator.recommendations.single.candidateId, 2);
      expect(saved.any((result) => result.candidateId == 1), isTrue);
    } finally {
      coordinator.dispose();
      await server.close(force: true);
    }
  });
}

class _ReadyVerifier implements HomepageVerifier {
  @override
  Future<ProbeResult> verify(
    Candidate candidate,
    int round,
    Cancellation cancel,
  ) async => ProbeResult(
    round: round,
    candidateId: candidate.id,
    stage: ProbeStage.homepage,
    status: ProbeStatus.ready,
    entryUrl: candidate.url,
    finalUrl: candidate.url,
    elapsed: Duration.zero,
    checkedAt: DateTime.now(),
  );
}
