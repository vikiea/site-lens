/// 播放页取「下一集」的那一件事：给一集，返回一个可以直接交给
/// `openRemoteCandidate` 的媒体候选。
///
/// 为什么要有这个接口：`RemotePlayerScreen` 只认识一集（它拿到的那份
/// [MediaCandidate]），而自动连播与跳集需要**下一集**的候选；候选只能由站点
/// 适配器产出（GLOSSARY: 线路 / 媒体候选），播放页不该自己认识任何一个站点。
///
/// 解析顺序固定为：先复用这一集已经选过的线路（[AdapterEpisodeSource.preferredLineId]），
/// 那条线路在这一集上已经没有了才退回目录的第一条线路。这样跳集不会悄悄换掉
/// 用户选的线路，也不会因为换集把用户带到另一条差点播不起来的线路上。
library;

import '../domain/models.dart';
import '../domain/site_adapter.dart';

/// 为一集产出媒体候选。
abstract interface class RemoteEpisodeSource {
  /// 第 [episodeNumber] 集的候选；取不到时抛 [SiteAdapterError]。
  Future<MediaCandidate> resolve(int episodeNumber, CancellationSignal cancel);
}

/// 用站点适配器实现 [RemoteEpisodeSource]。
///
/// 只读适配器已经公开的三样东西（选集、线路、候选），不碰凭证、不建任务、
/// 不碰下载；适配器自己的失败（不可用 / 不存在 / 内容坏）原样抛出。
class AdapterEpisodeSource implements RemoteEpisodeSource {
  AdapterEpisodeSource({
    required this.adapter,
    required this.seriesKey,
    this.preferredLineId,
    this.preferredQuality,
    this.preferredAudio,
  });

  final SiteAdapter adapter;
  final String seriesKey;

  /// 用户在这一集上选过的线路；它在这一集上不存在时退回第一条。
  final String? preferredLineId;

  /// 当前候选的清晰度与音轨。跳集时优先取同一档，取不到再退回这条线路的
  /// 第一档——换集不该顺手把清晰度换掉。
  final String? preferredQuality;
  final String? preferredAudio;

  @override
  Future<MediaCandidate> resolve(
    int episodeNumber,
    CancellationSignal cancel,
  ) async {
    final episodes = await adapter.episodes(seriesKey, cancel);
    final known = episodes.episodes
        .where((episode) => episode.episodeNumber == episodeNumber)
        .firstOrNull;
    if (known == null) {
      throw SiteAdapterError(
        SiteAdapterErrorKind.notFound,
        '目录里没有第 $episodeNumber 集',
      );
    }
    final lines = await adapter.lines(seriesKey, episodeNumber, cancel);
    if (lines.isEmpty) {
      throw SiteAdapterError(
        SiteAdapterErrorKind.unavailable,
        '第 $episodeNumber 集没有可用线路',
      );
    }
    final preferred = preferredLineId;
    final line = preferred == null
        ? lines.first
        : lines.where((known) => known.lineId == preferred).firstOrNull ??
              lines.first;
    final candidates = await adapter.candidates(line, cancel);
    if (candidates.isEmpty) {
      throw SiteAdapterError(
        SiteAdapterErrorKind.unavailable,
        '第 $episodeNumber 集的「${line.label}」没有给出候选',
      );
    }
    // 同一条线路里，和当前候选同一档清晰度/音轨的那个最接近用户的选择；
    // 没有就在同一条线路里取目录的第一档。
    final byQuality = preferredQuality == null
        ? const <MediaCandidate>[]
        : candidates
              .where(
                (candidate) =>
                    _sameLabel(candidate.qualityLabel, preferredQuality),
              )
              .toList();
    final byAudio = preferredAudio == null
        ? const <MediaCandidate>[]
        : candidates
              .where(
                (candidate) => _sameLabel(candidate.audioLabel, preferredAudio),
              )
              .toList();
    return byQuality
            .where(
              (candidate) =>
                  _sameLabel(candidate.audioLabel, preferredAudio) ||
                  preferredAudio == null,
            )
            .firstOrNull ??
        byQuality.firstOrNull ??
        byAudio.firstOrNull ??
        candidates.first;
  }

  static bool _sameLabel(String? left, String? right) {
    final a = left?.trim() ?? '';
    final b = right?.trim() ?? '';
    return a == b;
  }
}
