import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_export_queue.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';

Future<MediaTask> _taskFor(MediaTaskStore store) => store.create(
  MediaCandidate(
    id: 'export-queue-candidate',
    hostId: 1,
    generation: 1,
    sourceUrl: Uri.parse('https://example.com/watch'),
    mediaUrl: Uri.parse('https://cdn.example/video.m3u8'),
    title: '队列测试',
    mime: 'application/vnd.apple.mpegurl',
    source: MediaCandidateSource.dom,
  ),
);

MediaArtifact _artifactFor(MediaTask task) => MediaArtifact(
  taskId: task.id,
  location: '/tmp/${task.id}.mp4',
  name: '第1集.mp4',
  size: 1,
  createdAt: DateTime.utc(2026, 11, 4),
);

void main() {
  test('emits named retain/release and exclusive availability snapshots', () async {
    final tasks = ExportNotifyingMediaTaskStore();
    addTearDown(tasks.dispose);
    final task = await _taskFor(tasks);
    final events = <MediaTaskAvailabilityEvent>[];
    final subscription = tasks.availabilityEvents.listen(events.add);
    addTearDown(subscription.cancel);

    tasks.retain(task.id);
    tasks.release(task.id);
    tasks.acquireExclusive(task.id);
    tasks.releaseExclusive(task.id);

    expect(events.map((event) => event.kind), [
      MediaTaskAvailabilityEventKind.retained,
      MediaTaskAvailabilityEventKind.released,
      MediaTaskAvailabilityEventKind.exclusiveAcquired,
      MediaTaskAvailabilityEventKind.exclusiveReleased,
    ]);
    expect(events[0].referenceCount, 1);
    expect(events[0].canDelete, isFalse);
    expect(events[1].referenceCount, 0);
    expect(events[1].canDelete, isTrue);
    expect(events[2].exclusive, isTrue);
    expect(events[3].exclusive, isFalse);
  });

  test('waits for a retained task and wakes after release', () async {
    final tasks = ExportNotifyingMediaTaskStore();
    addTearDown(tasks.dispose);
    final task = await _taskFor(tasks);
    tasks.retain(task.id);
    var executions = 0;
    final queue = MediaExportQueue(
      tasks: tasks,
      availabilityPollInterval: const Duration(seconds: 30),
      execute: (request) async {
        executions++;
        return _artifactFor(request.task);
      },
    );
    addTearDown(queue.dispose);

    final pending = queue.export(task.id);
    await Future<void>.delayed(Duration.zero);
    expect(executions, 0);
    expect(queue.jobs.single.state, MediaExportJobState.waiting);

    tasks.release(task.id);
    final result = await pending;
    expect(result.taskId, task.id);
    expect(executions, 1);
  });

  test('coalesces automatic and manual requests by task id', () async {
    final tasks = MediaTaskStore();
    addTearDown(tasks.dispose);
    final task = await _taskFor(tasks);
    final started = Completer<void>();
    final finish = Completer<void>();
    var executions = 0;
    final forceValues = <bool>[];
    final queue = MediaExportQueue(
      tasks: tasks,
      execute: (request) async {
        executions++;
        forceValues.add(request.forceRegenerate);
        if (!started.isCompleted) started.complete();
        await finish.future;
        return _artifactFor(request.task);
      },
    );
    addTearDown(queue.dispose);

    await queue.enqueueAutomatic(task.id);
    await started.future;
    final manual = queue.export(task.id, forceRegenerate: true);
    finish.complete();

    final result = await manual;
    expect(result.taskId, task.id);
    expect(executions, 2);
    expect(forceValues, [false, true]);
  });

  test('retries unexpected failures within the bounded retry budget', () async {
    final tasks = MediaTaskStore();
    addTearDown(tasks.dispose);
    final task = await _taskFor(tasks);
    var executions = 0;
    final queue = MediaExportQueue(
      tasks: tasks,
      retryDelays: const [Duration.zero, Duration.zero],
      execute: (request) async {
        executions++;
        if (executions < 3) throw StateError('transient');
        return _artifactFor(request.task);
      },
    );
    addTearDown(queue.dispose);

    final result = await queue.export(task.id);
    expect(result.taskId, task.id);
    expect(executions, 3);
  });

  test('persists a waiting job and removes it after completion', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final tasks = ExportNotifyingMediaTaskStore(db: db);
    addTearDown(tasks.dispose);
    final candidate = MediaCandidate(
      id: 'durable-export-candidate',
      hostId: 1,
      generation: 1,
      sourceUrl: Uri.parse('https://example.com/watch'),
      mediaUrl: Uri.parse('https://cdn.example/video.m3u8'),
      title: '持久化队列测试',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );
    await db.saveMediaCandidate(candidate);
    final task = await tasks.create(candidate);
    await tasks.flush(task.id);
    tasks.retain(task.id);
    final queue = MediaExportQueue(
      tasks: tasks,
      db: db,
      availabilityPollInterval: const Duration(seconds: 30),
      execute: (request) async => _artifactFor(request.task),
    );
    addTearDown(queue.dispose);

    final pending = queue.export(task.id);
    await Future<void>.delayed(Duration.zero);
    expect((await db.mediaExportJobs()).single['state'], 'waiting');

    tasks.release(task.id);
    await pending;
    expect(await db.mediaExportJobs(), isEmpty);
  });
}
