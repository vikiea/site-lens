import 'dart:async';

/// Bounds concurrent media resource writes and gives active playback a
/// priority boost while aging ordinary work so it cannot starve forever.
class MediaTransferScheduler {
  MediaTransferScheduler({this.maxActive = 4});

  final int maxActive;
  final _queue = <_QueuedTransfer<dynamic>>[];
  var _active = 0;
  var _sequence = 0;

  Future<T> schedule<T>({
    required int priority,
    required Future<T> Function() action,
  }) {
    final completer = Completer<T>();
    _queue.add(
      _QueuedTransfer<T>(
        priority: priority,
        sequence: _sequence++,
        enqueuedAt: DateTime.now(),
        action: action,
        completer: completer,
      ),
    );
    _pump();
    return completer.future;
  }

  void _pump() {
    while (_active < maxActive && _queue.isNotEmpty) {
      _queue.sort((a, b) {
        final priority = b.effectivePriority.compareTo(a.effectivePriority);
        return priority == 0 ? a.sequence.compareTo(b.sequence) : priority;
      });
      final next = _queue.removeAt(0);
      _active++;
      Future.sync(next.action)
          .then(
            (value) => next.completer.complete(value),
            onError: next.completer.completeError,
          )
          .whenComplete(() {
            _active--;
            _pump();
          });
    }
  }
}

class _QueuedTransfer<T> {
  _QueuedTransfer({
    required this.priority,
    required this.sequence,
    required this.enqueuedAt,
    required this.action,
    required this.completer,
  });

  final int priority;
  final int sequence;
  final DateTime enqueuedAt;
  final Future<T> Function() action;
  final Completer<T> completer;

  int get effectivePriority =>
      priority + DateTime.now().difference(enqueuedAt).inSeconds;
}
