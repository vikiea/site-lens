import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';

void main() {
  test('row action mapping follows the task state', () {
    expect(
      mediaTaskRowActionForState(MediaTaskState.playable),
      MediaTaskRowAction.play,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.downloading),
      MediaTaskRowAction.pause,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.paused),
      MediaTaskRowAction.pause,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.failed),
      MediaTaskRowAction.retry,
    );
    expect(mediaTaskRowActionForState(MediaTaskState.queued), isNull);
  });
}
