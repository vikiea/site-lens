import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/discovery/probe_coordinator.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  for (final download in [false, true]) {
    test(
      'request timeout preserves the shared token and permits retry: file=$download',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final directory = await Directory.systemTemp.createTemp(
          'request-timeout-',
        );
        final pendingRoute = Completer<MediaNetworkRoute>();
        var attempts = 0;
        var hits = 0;
        server.listen((request) async {
          hits++;
          request.response.write('complete');
          await request.response.close();
        });
        final url = Uri.parse('http://127.0.0.1:${server.port}/');
        final cancel = Cancellation();
        final http = ControlledHttp(
          allowLocal: true,
          routeForAttempt: (_, _) => ++attempts == 1
              ? pendingRoute.future
              : Future.value(const MediaNetworkRoute()),
        );
        Future<void> fetch() async {
          if (download) {
            await http.fetchToFile(
              url,
              connect: const {'*'},
              document: url,
              cancel: cancel,
              destination: File('${directory.path}/download.part'),
              timeout: const Duration(milliseconds: 40),
            );
          } else {
            await http.fetch(
              url,
              connect: const {'*'},
              document: url,
              cancel: cancel,
              timeout: const Duration(milliseconds: 40),
            );
          }
        }

        try {
          await expectLater(fetch(), throwsA(isA<TimeoutException>()));
          expect(cancel.cancelled, isFalse);
          pendingRoute.complete(const MediaNetworkRoute());
          await fetch();
          expect(
            hits,
            1,
            reason: 'a timed-out route must never open a late socket',
          );
          if (download) {
            expect(
              await File('${directory.path}/download.part').readAsString(),
              'complete',
            );
          }
        } finally {
          cancel.cancel();
          await server.close(force: true);
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test('one probe timeout preserves other results and completes the discovery round', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write('ready');
      await request.response.close();
    });
    final saved = <ProbeResult>[];
    final coordinator = ProbeCoordinator(
      candidates: () async => [
        for (final id in [1, 2])
          Candidate(
            id: id,
            url: Uri.parse('http://127.0.0.1:${server.port}/$id'),
            label: '$id',
          ),
      ],
      httpProbe: HttpProbe(
        allowLocal: true,
        routeForAttempt: (url, _) async {
          if (url.path == '/1') throw TimeoutException('route timed out');
          return const MediaNetworkRoute();
        },
      ),
      verifier: _ReadyVerifier(),
      save: (result) async => saved.add(result),
    );
    try {
      await coordinator.run();
      expect(coordinator.running, isFalse);
      expect(coordinator.results[1]?.status, ProbeStatus.timeout);
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
