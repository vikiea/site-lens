import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_export_runtime.dart';
import 'package:site_lens/media/native_media_runtime.dart';

import 'media3_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Media3 parity preserves B frame PTS and raw AAC across TS fMP4 AES',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${support.path}/media3-parity-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final native = NativeExportRuntime();
      final player = NativeMediaRuntime();
      try {
        final manifest = await unpackMedia3Fixtures(root);
        for (final raw in manifest['fixtures'] as List) {
          final fixture = Map<String, Object?>.from(raw as Map);
          final name = fixture['name'] as String;
          debugPrint('MEDIA3_PARITY_BEGIN fixture=$name');
          final playlist = File('${root.path}/${fixture['playlist']}');
          final output = File('${root.path}/$name.mp4');
          await native.muxHls(
            playlist: playlist.path,
            output: output.path,
            jobId: 'parity-$name',
          );
          expect(
            await native.validateOutput(output.path),
            isTrue,
            reason: name,
          );
          final details = await native.inspectSamples(output.path);
          final actualTracks = (details['tracks'] as List)
              .map((raw) => Map<String, Object?>.from(raw as Map))
              .toList();
          final expectedTracks = (fixture['tracks'] as List)
              .map((raw) => Map<String, Object?>.from(raw as Map))
              .toList();
          expect(actualTracks, hasLength(expectedTracks.length), reason: name);
          final shifts = <int>[];
          for (final expected in expectedTracks) {
            final kind = expected['kind'] as String;
            final actual = actualTracks.singleWhere(
              (track) => (track['mime'] as String).startsWith('$kind/'),
            );
            expect(
              actual['sampleCount'],
              expected['sampleCount'],
              reason: '$name $kind sample count',
            );
            expect(actual['reportedSamplesTruncated'], isFalse);
            final pts = (actual['presentationTimesUs'] as List).cast<int>();
            final inputPts = (expected['ptsUs'] as List).cast<int>();
            expect(pts.length, inputPts.length);
            final shift = pts.first - inputPts.first;
            shifts.add(shift);
            for (var index = 0; index < pts.length; index++) {
              expect(
                (pts[index] - inputPts[index] - shift).abs(),
                lessThanOrEqualTo(150),
                reason: '$name $kind PTS/decode order at $index',
              );
            }
            if (kind == 'video') {
              expect(actual['width'], 160);
              expect(actual['height'], 96);
              expect(
                pts.indexed.skip(1).any((item) => item.$2 < pts[item.$1 - 1]),
                isTrue,
                reason: 'B-frame presentation timestamps must stay nonmonotonic in decode order',
              );
              expect((actual['keyFrameSampleIndices'] as List).first, 0);
            } else {
              expect(actual['sampleRate'], 48000);
              expect(actual['channelCount'], 2);
              expect(actual['hasAdtsHeader'], isFalse);
              expect((actual['csd'] as Map)['csd-0'], isNotEmpty);
              for (var index = 1; index < pts.length; index++) {
                expect(pts[index], greaterThan(pts[index - 1]));
              }
            }
          }
          expect(
            (shifts.first - shifts.last).abs(),
            lessThanOrEqualTo(150),
            reason: '$name common A/V offset',
          );
          final metadata = await native.inspect(output.path);
          expect(
            metadata['durationMs'],
            inInclusiveRange(3900, 4300),
            reason: '$name EOS duration',
          );
          expect(metadata['width'], 160);
          expect(metadata['height'], 96);
          if (fixture['name'] == 'h264_ts') {
            expect(
              metadata['thumbnailPath'],
              isNotNull,
              reason: 'FrameExtractor produces the thumbnail',
            );
            expect(
              await File(metadata['thumbnailPath'] as String).length(),
              greaterThan(0),
            );
            final candidate = MediaCandidate(
              id: 'parity-playback',
              hostId: 1,
              generation: 1,
              sourceUrl: Uri.parse('https://example.org/test'),
              mediaUrl: Uri.parse('https://example.org/test.mp4'),
              title: 'Synthetic parity',
              mime: 'video/mp4',
              source: MediaCandidateSource.dom,
            );
            final tasks = MediaTaskStore(directoryProvider: () async => root);
            final task = tasks.create(candidate);
            final session = await player.openLocal(task, output);
            final deadline = DateTime.now().add(const Duration(seconds: 15));
            while (DateTime.now().isBefore(deadline)) {
              await tester.pump(const Duration(milliseconds: 100));
              final state = await player.state(sessionId: session.id);
              expect(
                state.state,
                isNot(NativePlaybackState.failed),
                reason: state.errorCode,
              );
              if (state.state == NativePlaybackState.completed ||
                  state.positionMs >= 3800) {
                break;
              }
            }
            final ended = await player.state(sessionId: session.id);
            expect(ended.positionMs, greaterThanOrEqualTo(3800));
            await player.seek(
              const Duration(milliseconds: 1800),
              sessionId: session.id,
            );
            await player.play(sessionId: session.id);
            await tester.pump(const Duration(milliseconds: 400));
            expect(
              (await player.state(sessionId: session.id)).positionMs,
              greaterThanOrEqualTo(1800),
            );
            await player.close(sessionId: session.id);
          }
          debugPrint('MEDIA3_PARITY_PASS fixture=$name');
        }
      } finally {
        if (player.active != null) {
          await player.close(sessionId: player.active!.id);
        }
        await player.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'Media3 refuses remote resources path escapes and discontinuities',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final root = await Directory(
        '${support.path}/media3-boundary-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final native = NativeExportRuntime();
      try {
        await unpackMedia3Fixtures(root);
        final original = await File('${root.path}/h264_ts/index.m3u8')
            .readAsString();
        final playlist = File('${root.path}/h264_ts/rejected.m3u8');
        final segment = original
            .split('\n')
            .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
        for (final value in [
          original.replaceFirst(segment, 'https://127.0.0.1:1/forbidden.ts'),
          original.replaceFirst(segment, '../hevc_ts/seg00.ts'),
          original.replaceFirst('#EXTINF:', '#EXT-X-DISCONTINUITY\n#EXTINF:'),
        ]) {
          await playlist.writeAsString(value);
          final output = File('${root.path}/rejected.mp4');
          await expectLater(
            native.muxHls(playlist: playlist.path, output: output.path),
            throwsA(isA<PlatformException>()),
          );
          expect(await output.exists(), isFalse);
          expect(await File('${output.path}.part').exists(), isFalse);
        }
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
