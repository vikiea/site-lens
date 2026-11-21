import '../domain/models.dart';
import '../domain/site_adapter.dart';
import '../theater/series_line_memory.dart';
import 'series_batch_download.dart';

/// Turns a 剧集 selection into media candidates and names the batch folder.
///
/// The store owns the selection model and the per-row phases; this resolver
/// owns the two things only the detail page can know: which line serves an
/// episode, and what the batch is called. It never touches playback — a batch
/// and a remote play of the same episode are two independent actions
/// (ADR-0005, ADR-0010).
class SeriesBatchDownloadResolver {
  SeriesBatchDownloadResolver({
    required this.adapter,
    required this.memory,
    required this.seriesKey,
    required this.seriesTitle,
    this.hostId = 0,
    this.generation = 0,
  });

  final SiteAdapter adapter;
  final SeriesLineMemory memory;
  final String seriesKey;

  /// The detail page's series title, and the batch folder when nothing more
  /// specific is available.
  final String seriesTitle;

  /// Identity stamped on a candidate that carried none, so a task row can
  /// still be attributed to the page it came from.
  final int hostId;
  final int generation;

  /// The candidate the detail page would have picked for [episodeNumber]: the
  /// remembered line first, else the catalog's first line, then that line's
  /// first representation.
  ///
  /// One adapter round trip per call, and callers issue these sequentially:
  /// the page adapter is not documented as concurrency safe, and a batch of
  /// thirty episodes must not become thirty parallel page reads.
  Future<MediaCandidate?> candidateFor(
    int episodeNumber,
    CancellationSignal cancel,
  ) async {
    final lines = await adapter.lines(seriesKey, episodeNumber, cancel);
    if (lines.isEmpty) return null;
    final chosen =
        memory.resolved(adapter.id, seriesKey, episodeNumber, [
          for (final line in lines) line.lineId,
        ]) ??
        lines.first.lineId;
    Line? line;
    for (final known in lines) {
      if (known.lineId == chosen) line = known;
    }
    if (line == null) return null;
    final candidates = await adapter.candidates(line, cancel);
    if (candidates.isEmpty) return null;
    return _withIdentity(candidates.first, episodeNumber);
  }

  /// The batch folder for [selection]. Falls back from the page's title to the
  /// candidates' shared title, then to a neutral batch name.
  Future<({String? batchDirectory, bool fallback})> batchDirectoryFor(
    List<SeriesBatchEpisode> selection,
    List<MediaCandidate> known,
  ) async {
    final named = mediaBatchDirectoryName(known);
    if (named != null) return (batchDirectory: named, fallback: false);
    final title = seriesTitle.trim();
    if (title.isNotEmpty) return (batchDirectory: title, fallback: false);
    if (known.isEmpty) return (batchDirectory: null, fallback: true);
    return (
      batchDirectory: mediaBatchFallbackDirectoryName(known),
      fallback: true,
    );
  }

  MediaCandidate _withIdentity(MediaCandidate candidate, int episodeNumber) {
    final sameHost = candidate.hostId > 0 && candidate.generation > 0;
    final sameEpisode = candidate.episodeNumber != null;
    if (sameHost && sameEpisode) return candidate;
    return MediaCandidate(
      id: candidate.id,
      hostId: sameHost ? candidate.hostId : hostId,
      generation: sameHost ? candidate.generation : generation,
      sourceUrl: candidate.sourceUrl,
      mediaUrl: candidate.mediaUrl,
      title: candidate.title,
      mime: candidate.mime,
      source: candidate.source,
      seriesKey: candidate.seriesKey,
      episodeNumber: candidate.episodeNumber ?? episodeNumber,
      representationRank: candidate.representationRank,
      qualityLabel: candidate.qualityLabel,
      audioLabel: candidate.audioLabel,
      thumbnailUrl: candidate.thumbnailUrl,
      durationMs: candidate.durationMs,
      createdAt: candidate.createdAt,
      manifestHeaders: candidate.manifestHeaders,
      resourceHeaders: candidate.resourceHeaders,
      seriesTitle: candidate.seriesTitle,
    );
  }
}
