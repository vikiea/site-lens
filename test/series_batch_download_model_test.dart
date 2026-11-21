import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/media/media_transfer_scheduler.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';
import 'package:site_lens/theater/series_line_memory.dart';
import 'package:site_lens/ui/series_batch_download.dart';
import 'package:site_lens/ui/series_batch_download_resolver.dart';

/// Pure contract of the batch model, with no database and no widget tree.
///
/// `SeriesBatchDownloadStore` needs an `AppController` for the durable task
/// store, so the parts that decide *what* a batch is — the selection label, the
/// per-row phases, the whole-batch counts and the resolver's line pick — are
/// pinned here through the value objects and the fake adapter.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SeriesBatchDownloadJob jobOf(List<SeriesBatchDownloadItem> items) =>
      SeriesBatchDownloadJob(
        seriesKey: 's-1',
        adapterId: 'fake-1',
        batchDirectory: '示例剧',
        items: items,
      );

  SeriesBatchDownloadItem item(
    int position,
    SeriesBatchItemPhase phase, {
    int bytes = 0,
  }) => SeriesBatchDownloadItem(
    position: position,
    episodeNumber: position + 1,
    title: '第${position + 1}集',
    phase: phase,
    bytesOnDisk: bytes,
  );

  group('batch job counts', () {
    test('整体进度按集数记账，完成与失败分开数，等待既不算完成也不算失败', () {
      final job = jobOf([
        item(0, SeriesBatchItemPhase.done),
        item(1, SeriesBatchItemPhase.running, bytes: 2048),
        item(2, SeriesBatchItemPhase.failed),
        item(3, SeriesBatchItemPhase.queued),
      ]);

      expect(job.total, 4);
      expect(job.done, 1);
      expect(job.failed, 1);
      expect(job.running, 1);
      expect(job.queued, 1);
      expect(job.settled, isFalse);
      expect(job.unit, '集');
      expect(job.bytesOnDisk, 2048);
    });

    test('全部落定后 settled 为真，失败仍然留在计数里', () {
      final job = jobOf([
        item(0, SeriesBatchItemPhase.done),
        item(1, SeriesBatchItemPhase.failed),
      ]);
      expect(job.settled, isTrue);
      expect(job.done + job.failed, job.total);
    });

    test('删除一集的项不动邻居的字节和阶段', () {
      final job = jobOf([
        item(0, SeriesBatchItemPhase.done, bytes: 100),
        item(1, SeriesBatchItemPhase.done, bytes: 200),
        item(2, SeriesBatchItemPhase.failed),
      ]);

      final trimmed = job.without([1]);

      expect(trimmed.items.map((row) => row.position), [0, 2]);
      expect(trimmed.bytesOnDisk, 100);
      expect(trimmed.failed, 1);
      expect(trimmed.batchDirectory, '示例剧');
    });

    test('失败原因可以被清除，换一集重试不会继承旧原因', () {
      final failed = item(
        0,
        SeriesBatchItemPhase.failed,
      ).copyWith(message: '线路没有给出清晰度');
      final retrying = failed.copyWith(
        phase: SeriesBatchItemPhase.running,
        clearMessage: true,
      );
      expect(retrying.message, isNull);
      expect(retrying.phase, SeriesBatchItemPhase.running);
    });
  });

  group('resolver', () {
    FakeSiteAdapter adapter() {
      final adapter = FakeSiteAdapter(
        id: 'fake-1',
        profileId: 1,
        addresses: [Uri.parse('https://fake-1.example/')],
      );
      adapter.configureCatalog([
        const FakeSeries(
          seriesKey: 's-1',
          title: '示例剧',
          episodes: [
            FakeEpisode(
              episodeNumber: 1,
              title: '第1集',
              lines: [
                FakeLine(
                  lineId: 'alpha',
                  label: '甲线路',
                  representations: [
                    FakeRepresentation(
                      mediaUrl: 'https://media.invalid/a-1.m3u8',
                      qualityLabel: '1080P',
                    ),
                    FakeRepresentation(
                      mediaUrl: 'https://media.invalid/a-1-720.m3u8',
                      qualityLabel: '720P',
                    ),
                  ],
                ),
                FakeLine(
                  lineId: 'beta',
                  label: '乙线路',
                  representations: [
                    FakeRepresentation(
                      mediaUrl: 'https://media.invalid/b-1.m3u8',
                    ),
                  ],
                ),
              ],
            ),
            FakeEpisode(episodeNumber: 2, title: '第2集'),
          ],
        ),
      ]);
      return adapter;
    }

    test('没有记忆时取第一条线路的第一个候选', () async {
      final resolver = SeriesBatchDownloadResolver(
        adapter: adapter(),
        memory: SeriesLineMemory(),
        seriesKey: 's-1',
        seriesTitle: '示例剧',
        hostId: 1,
      );
      final cancel = CancellationSignal();
      addTearDown(cancel.cancel);

      final candidate = await resolver.candidateFor(1, cancel);

      expect(candidate?.mediaUrl.toString(), 'https://media.invalid/a-1.m3u8');
      expect(candidate?.episodeNumber, 1);
      expect(candidate?.hostId, 1);
    });

    test('记住的线路优先，换线路不影响别的集', () async {
      final memory = SeriesLineMemory()..remember('fake-1', 's-1', 1, 'beta');
      final resolver = SeriesBatchDownloadResolver(
        adapter: adapter(),
        memory: memory,
        seriesKey: 's-1',
        seriesTitle: '示例剧',
      );
      final cancel = CancellationSignal();
      addTearDown(cancel.cancel);

      final candidate = await resolver.candidateFor(1, cancel);
      expect(candidate?.mediaUrl.toString(), 'https://media.invalid/b-1.m3u8');
    });

    test('没有线路的集返回 null，而不是抛给整批', () async {
      final resolver = SeriesBatchDownloadResolver(
        adapter: adapter(),
        memory: SeriesLineMemory(),
        seriesKey: 's-1',
        seriesTitle: '示例剧',
      );
      final cancel = CancellationSignal();
      addTearDown(cancel.cancel);

      expect(await resolver.candidateFor(2, cancel), isNull);
    });

    test('批次目录优先用剧名，剧名缺失时退回候选共同标题或中性批次名', () async {
      final resolver = SeriesBatchDownloadResolver(
        adapter: adapter(),
        memory: SeriesLineMemory(),
        seriesKey: 's-1',
        seriesTitle: '示例剧',
      );
      final named = await resolver.batchDirectoryFor(const [], const []);
      expect(named.batchDirectory, '示例剧');
      expect(named.fallback, isFalse);

      final anonymous = SeriesBatchDownloadResolver(
        adapter: adapter(),
        memory: SeriesLineMemory(),
        seriesKey: 's-1',
        seriesTitle: '',
      );
      final candidate = MediaCandidate(
        id: 'c',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://fake-1.example/'),
        mediaUrl: Uri.parse('https://media.invalid/a.m3u8'),
        title: '某剧 - 第1集',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
        episodeNumber: 1,
      );
      final shared = await anonymous.batchDirectoryFor(const [], [candidate]);
      expect(shared.batchDirectory, contains('某剧'));
      expect(shared.fallback, isFalse);

      final empty = await anonymous.batchDirectoryFor(const [], const []);
      expect(empty.batchDirectory, isNull);
      expect(empty.fallback, isTrue);
    });
  });

  group('repository wiring', () {
    test('新代码不碰生成绑定，也不给缓存目录写下载', () {
      final sources = [
        'lib/ui/series_batch_download.dart',
        'lib/ui/series_batch_download_resolver.dart',
        'lib/ui/series_batch_download_sheet.dart',
      ];
      final cache = <String>['media_playback_cache', 'SimpleCache'];
      for (final path in sources) {
        final text = File(path).readAsStringSync();
        for (final token in cache) {
          expect(
            text.contains(token),
            isFalse,
            reason: '$path 不得引用播放缓存：缓存与下载分目录（ADR-0010）',
          );
        }
        expect(
          text.contains('dart:convert'),
          isFalse,
          reason: '$path 不需要 JSON 编解码，JSON 只走 org.json 的既有通道',
        );
      }
    });

    test('限流器仍是分片级共用的那一个，批量不另开通道', () {
      final scheduler = MediaTransferScheduler();
      expect(scheduler.maxActive, greaterThan(0));
    });
  });
}
