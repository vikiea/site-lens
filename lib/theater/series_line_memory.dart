/// Which 线路 the user picked for one 选集, remembered for the app's lifetime.
///
/// The scope is deliberately narrow: **adapter + series + episode number**. A
/// choice belongs to one episode, so browsing to another episode or another
/// series never inherits it, and two profiles that happen to share a
/// `seriesKey` stay independent because the adapter id is part of the key.
///
/// What is *not* part of the scope: quality, audio track and candidate. Those
/// are 媒体候选 — a line yields them, and the player receives one candidate
/// while the user picks a line (`GLOSSARY.md`). Changing a candidate therefore
/// cannot disturb the remembered line.
///
/// This store is intentionally in memory only. Durable preferences are not part
/// of this ticket: the memory only has to survive switching lines, switching
/// candidates and leaving the detail page within one run.
class SeriesLineMemory {
  /// Key: `adapterId/seriesKey/episodeNumber`.
  final Map<String, String> _lines = {};

  static String keyOf(String adapterId, String seriesKey, int episodeNumber) =>
      '$adapterId/$seriesKey/$episodeNumber';

  /// The line last chosen for this episode, or null when the user never chose
  /// one — the page falls back to the catalog's first line, but never invents
  /// a choice of its own.
  String? remembered(String adapterId, String seriesKey, int episodeNumber) =>
      _lines[keyOf(adapterId, seriesKey, episodeNumber)];

  /// Remembers [lineId] for this episode only.
  void remember(
    String adapterId,
    String seriesKey,
    int episodeNumber,
    String lineId,
  ) {
    _lines[keyOf(adapterId, seriesKey, episodeNumber)] = lineId;
  }

  /// The remembered line when the episode still offers it, otherwise null.
  ///
  /// A line that disappeared from the catalog is not silently swapped for
  /// another one here: the page decides what to show and says the line is gone.
  String? resolved(
    String adapterId,
    String seriesKey,
    int episodeNumber,
    Iterable<String> availableLineIds,
  ) {
    final chosen = remembered(adapterId, seriesKey, episodeNumber);
    if (chosen == null) return null;
    return availableLineIds.contains(chosen) ? chosen : null;
  }
}
