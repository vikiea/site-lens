import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../media/dlna_service.dart';
import '../media/media_service.dart';
import 'app_controller.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';
import 'app_theme.dart';

/// In-app surface for the native Media3 texture. The route keeps the texture
/// and controls visible until the user leaves it, including while a stream is
/// buffering or reports a decoder error.
class NativeMediaPlayerScreen extends StatefulWidget {
  const NativeMediaPlayerScreen({
    super.key,
    required this.app,
    required this.session,
  });

  final AppController app;
  final NativePlaybackSession session;

  @override
  State<NativeMediaPlayerScreen> createState() =>
      _NativeMediaPlayerScreenState();
}

class _NativeMediaPlayerScreenState extends State<NativeMediaPlayerScreen> {
  late NativePlaybackSession _session = widget.session;
  StreamSubscription<NativePlaybackSession>? _states;
  Timer? _hideTimer;
  Timer? _statePoller;
  bool _controlsVisible = true;
  bool _seeking = false;
  bool _landscape = false;
  bool _closing = false;

  bool get _canControl =>
      !_closing &&
      _session.state != NativePlaybackState.stopped &&
      _session.state != NativePlaybackState.failed;

  @override
  void initState() {
    super.initState();
    _states = widget.app.nativeMedia.states.listen((next) {
      if (!mounted || next.id != _session.id) return;
      setState(() => _session = next);
      _scheduleHide();
    });
    _statePoller = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_refreshState()),
    );
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_controlsVisible || _session.state != NativePlaybackState.playing) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          !_seeking &&
          _session.state == NativePlaybackState.playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleHide();
  }

  Future<void> _command(Future<NativePlaybackSession> Function() action) async {
    if (!_canControl) return;
    try {
      final next = await action();
      if (!mounted || next.id != _session.id) return;
      setState(() => _session = next);
      _scheduleHide();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('播放器操作失败：$error')));
      }
    }
  }

  Future<void> _refreshState() async {
    if (!_canControl || _seeking) return;
    try {
      final next = await widget.app.nativeMedia.state(sessionId: _session.id);
      if (mounted && next.id == _session.id) setState(() => _session = next);
    } catch (_) {}
  }

  Future<void> _seekBy(int seconds) async {
    final duration = _session.durationMs;
    final target = _session.positionMs + seconds * 1000;
    final clamped = duration > 0
        ? target.clamp(0, duration)
        : target.clamp(0, 1 << 62);
    await _command(
      () => widget.app.nativeMedia.seek(
        Duration(milliseconds: clamped),
        sessionId: _session.id,
      ),
    );
  }

  Future<void> _seekTo(double value) async {
    final target = value.round().clamp(0, _session.durationMs);
    await _command(
      () => widget.app.nativeMedia.seek(
        Duration(milliseconds: target),
        sessionId: _session.id,
      ),
    );
  }

  Future<void> _toggleOrientation() async {
    _landscape = !_landscape;
    await SystemChrome.setPreferredOrientations(
      _landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    if (mounted) setState(() {});
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _hideTimer?.cancel();
    try {
      await widget.app.nativeMedia.close(sessionId: _session.id);
    } catch (_) {}
  }

  @override
  void dispose() {
    _states?.cancel();
    _hideTimer?.cancel();
    _statePoller?.cancel();
    unawaited(SystemChrome.setPreferredOrientations([]));
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: Center(
                child: _session.textureId == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Texture(textureId: _session.textureId!),
              ),
            ),
            if (_session.state == NativePlaybackState.buffering ||
                _session.state == NativePlaybackState.preparing)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            if (_controlsVisible) ...[
              Positioned(
                top: 4,
                left: 4,
                right: 4,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      tooltip: '返回',
                      color: Colors.white,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    IconButton(
                      tooltip: _landscape ? '竖屏' : '横屏',
                      color: Colors.white,
                      icon: Icon(
                        _landscape
                            ? Icons.stay_current_portrait
                            : Icons.stay_current_landscape,
                      ),
                      onPressed: _toggleOrientation,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Slider(
                      min: 0,
                      max: math.max(1, _session.durationMs).toDouble(),
                      value: _session.positionMs
                          .clamp(0, math.max(1, _session.durationMs))
                          .toDouble(),
                      onChangeStart: (_) {
                        _seeking = true;
                        _hideTimer?.cancel();
                      },
                      onChanged: (value) {
                        if (mounted) {
                          setState(() {
                            _session = NativePlaybackSession(
                              id: _session.id,
                              candidateId: _session.candidateId,
                              state: _session.state,
                              textureId: _session.textureId,
                              positionMs: value.round(),
                              durationMs: _session.durationMs,
                              speed: _session.speed,
                              errorCode: _session.errorCode,
                            );
                          });
                        }
                      },
                      onChangeEnd: (value) {
                        _seeking = false;
                        unawaited(_seekTo(value));
                        _scheduleHide();
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '快退 10 秒',
                          color: Colors.white,
                          icon: const Icon(Icons.replay_10),
                          onPressed: _canControl ? () => _seekBy(-10) : null,
                        ),
                        IconButton(
                          tooltip: _session.state == NativePlaybackState.playing
                              ? '暂停'
                              : '播放',
                          color: Colors.white,
                          icon: Icon(
                            _session.state == NativePlaybackState.playing
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                            size: 40,
                          ),
                          onPressed: _canControl
                              ? () => _command(
                                  _session.state == NativePlaybackState.playing
                                      ? () => widget.app.nativeMedia.pause(
                                          sessionId: _session.id,
                                        )
                                      : () => widget.app.nativeMedia.play(
                                          sessionId: _session.id,
                                        ),
                                )
                              : null,
                        ),
                        IconButton(
                          tooltip: '快进 10 秒',
                          color: Colors.white,
                          icon: const Icon(Icons.forward_10),
                          onPressed: _canControl ? () => _seekBy(10) : null,
                        ),
                        IconButton(
                          tooltip: '停止',
                          color: Colors.white,
                          icon: const Icon(Icons.stop_circle_outlined),
                          onPressed: _canControl
                              ? () => _command(
                                  () => widget.app.nativeMedia.stop(
                                    sessionId: _session.id,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Durable media task surface. The screen is deliberately independent from a
/// browser tab: a task can be resumed after its source tab is gone.
class MediaTasksScreen extends StatefulWidget {
  const MediaTasksScreen({super.key, required this.app});
  final AppController app;

  @override
  State<MediaTasksScreen> createState() => _MediaTasksScreenState();
}

class _MediaTasksScreenState extends State<MediaTasksScreen> {
  bool busy = false;
  Timer? _poller;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    if (widget.app.nativeDownloads != null) {
      _poller = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_pollNativeTasks());
      });
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _pollNativeTasks() async {
    if (!mounted || busy || _polling) return;
    _polling = true;
    try {
      for (final task in widget.app.mediaTasks.tasks) {
        if (task.state == MediaTaskState.downloading ||
            task.state == MediaTaskState.paused) {
          try {
            await _refreshNative(task);
          } catch (_) {
            // The task row retains its last durable state; a transient native
            // status failure must not interrupt the settings/media screen.
          }
        }
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    await safely(context, action);
    if (mounted) setState(() => busy = false);
  }

  Future<void> _refreshNative(MediaTask task) async {
    final native = widget.app.nativeDownloads;
    if (native == null) throw StateError('iOS 不支持原生后台下载');
    final status = await native.status(task.id);
    final state = status['state'] as String?;
    final bytes = (status['bytesDownloaded'] as num?)?.toInt();
    final total = (status['totalBytes'] as num?)?.toInt();
    if (bytes != null) {
      widget.app.mediaTasks.updateProgress(task.id, bytes, totalBytes: total);
    }
    final localUri = status['localUri'] as String?;
    if (localUri != null && localUri.startsWith('file://')) {
      widget.app.mediaTasks.setLocalRef(
        task.id,
        Uri.parse(localUri).toFilePath(),
      );
    }
    if (state == 'paused' && task.state == MediaTaskState.downloading) {
      widget.app.mediaTasks.transition(task.id, MediaTaskState.paused);
    }
    if (state == 'completed' && task.state == MediaTaskState.downloading) {
      widget.app.mediaTasks.transition(task.id, MediaTaskState.completed);
      widget.app.mediaTasks.transition(task.id, MediaTaskState.playable);
    }
    if (state == 'failed' && task.state == MediaTaskState.downloading) {
      widget.app.mediaTasks.transition(
        task.id,
        MediaTaskState.failed,
        errorCode: status['errorCode']?.toString(),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _play(MediaTask task) async {
    final cached = await widget.app.mediaTasks.cachedFile(task.id);
    if (cached != null) {
      final session = await widget.app.nativeMedia.openLocal(task, cached);
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                NativeMediaPlayerScreen(app: widget.app, session: session),
          ),
        );
      }
      return;
    }
    final candidate = await widget.app.db.mediaCandidate(task.candidateId);
    if (candidate == null) throw StateError('媒体候选已不存在');
    final session = await widget.app.nativeMedia.open(
      candidate,
      hostId: task.hostId,
      generation: task.generation,
      sourceUrl: task.sourceUrl,
      sessionId: 'play_${task.id}',
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            NativeMediaPlayerScreen(app: widget.app, session: session),
      ),
    );
  }

  Future<void> _togglePause(MediaTask task) async {
    final candidate = await widget.app.db.mediaCandidate(task.candidateId);
    if (candidate == null) throw StateError('媒体候选已不存在');
    if (task.state == MediaTaskState.downloading) {
      await widget.app.mediaDownloads.pauseNative(task.id);
    } else if (task.state == MediaTaskState.paused) {
      await widget.app.mediaDownloads.resumeNative(task.id, candidate);
    }
    if (mounted) setState(() {});
  }

  Future<void> _cast(MediaTask task) async {
    final file = await widget.app.mediaTasks.cachedFile(task.id);
    if (file == null) throw StateError('该任务没有可投屏的本地文件');
    final isHls = file.path.toLowerCase().endsWith('.m3u8');
    final devices = await const DlnaDiscovery().discover();
    if (devices.isEmpty) throw StateError('局域网内没有发现可用的 DLNA 接收端');
    final device = devices.first;
    await DlnaCastController(widget.app.castSessions).cast(
      device: device,
      mediaTaskId: task.id,
      mediaUrl: file.uri,
      localFile: isHls ? null : file,
      localHlsPlaylist: isHls ? file : null,
      mime: isHls ? 'application/vnd.apple.mpegurl' : 'video/mp4',
      title: task.id,
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已投屏到 ${device.name}')));
    }
  }

  Future<void> _export(MediaTask task) async {
    final file = await widget.app.mediaTasks.cachedFile(task.id);
    if (file == null || !file.path.toLowerCase().endsWith('.m3u8')) {
      throw StateError('当前缓存不是可导出的本地 HLS 清单');
    }
    final input = await const HlsPlaylistParser().parseFile(file.uri);
    final result = await widget.app.mediaExports.export(task.id, input);
    if (result.state != ExportState.deliverable) {
      throw StateError(result.errorCode ?? '导出失败');
    }
    final destination = await FilePicker.saveFile(
      bytes: Uint8List(0),
      dialogTitle: '导出 MP4',
      fileName: '${task.id}.mp4',
      mimeType: 'video/mp4',
    );
    if (destination == null) return;
    await widget.app.mediaExports.deliver(result, destination);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('MP4 已交付')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.app.mediaTasks.tasks;
    return SiteLensPageScaffold(
      title: '媒体任务',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          12,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          if (widget.app.nativeMedia.active != null)
            SiteLensPanel(
              child: Row(
                children: [
                  const Icon(Icons.play_circle_filled),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '原生播放：${widget.app.nativeMedia.active!.state.name}',
                    ),
                  ),
                  IconButton(
                    tooltip: '暂停',
                    icon: const Icon(Icons.pause),
                    onPressed: () => _run(() async {
                      await widget.app.nativeMedia.pause(
                        sessionId: widget.app.nativeMedia.active?.id,
                      );
                      if (mounted) setState(() {});
                    }),
                  ),
                  IconButton(
                    tooltip: '继续',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => _run(() async {
                      await widget.app.nativeMedia.play(
                        sessionId: widget.app.nativeMedia.active?.id,
                      );
                      if (mounted) setState(() {});
                    }),
                  ),
                  IconButton(
                    tooltip: '停止',
                    icon: const Icon(Icons.stop),
                    onPressed: () => _run(() async {
                      await widget.app.nativeMedia.stop(
                        sessionId: widget.app.nativeMedia.active?.id,
                      );
                      if (mounted) setState(() {});
                    }),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          SiteLensPanel(
            child: Text(
              '下载、播放和导出任务独立于标签页保存。凭据不会写入任务或缓存；需要登录态时会回到重新授权。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: SiteLensMetrics.sectionGap),
          if (tasks.isEmpty)
            const SiteLensPanel(
              child: ListTile(
                leading: Icon(Icons.download_done),
                title: Text('暂无媒体任务'),
                subtitle: Text('在浏览器的「媒体候选」中选择地址开始缓存。'),
              ),
            ),
          for (final task in tasks) ...[
            SiteLensPanel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  FutureBuilder<MediaCandidate?>(
                    future: widget.app.db.mediaCandidate(task.candidateId),
                    builder: (context, snapshot) => ListTile(
                      leading: _TaskThumbnail(
                        task: task,
                        candidate: snapshot.data,
                      ),
                      title: Text(
                        _taskTitle(task, snapshot.data),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${task.state.name} · ${_taskProgressLabel(task)}${task.errorCode == null ? '' : ' · ${task.errorCode}'}',
                      ),
                      onTap: task.state == MediaTaskState.playable
                          ? () => unawaited(_run(() => _play(task)))
                          : null,
                      trailing: PopupMenuButton<String>(
                        enabled: !busy,
                        onSelected: (value) {
                          switch (value) {
                            case 'refresh':
                              unawaited(_run(() => _refreshNative(task)));
                            case 'play':
                              unawaited(_run(() => _play(task)));
                            case 'cast':
                              unawaited(_run(() => _cast(task)));
                            case 'export':
                              unawaited(_run(() => _export(task)));
                            case 'cancel':
                              unawaited(
                                _run(() async {
                                  final native = widget.app.nativeDownloads;
                                  if (native == null) {
                                    throw StateError('iOS 不支持原生后台下载');
                                  }
                                  await native.cancel(task.id);
                                  if (widget.app.mediaTasks
                                          .task(task.id)
                                          ?.state ==
                                      MediaTaskState.downloading) {
                                    widget.app.mediaTasks.transition(
                                      task.id,
                                      MediaTaskState.cancelled,
                                    );
                                  }
                                  if (mounted) setState(() {});
                                }),
                              );
                            case 'pause':
                              unawaited(_run(() => _togglePause(task)));
                            case 'delete':
                              unawaited(
                                _run(() async {
                                  final native = widget.app.nativeDownloads;
                                  if (native != null) {
                                    await native.delete(task.id);
                                  }
                                  await widget.app.mediaTasks.delete(task.id);
                                  if (mounted) setState(() {});
                                }),
                              );
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'refresh',
                            child: Text('刷新后台状态'),
                          ),
                          if (task.state == MediaTaskState.playable)
                            const PopupMenuItem(
                              value: 'play',
                              child: Text('原生播放'),
                            ),
                          if (task.state == MediaTaskState.playable)
                            const PopupMenuItem(
                              value: 'cast',
                              child: Text('DLNA 投屏'),
                            ),
                          if (task.state == MediaTaskState.playable)
                            const PopupMenuItem(
                              value: 'export',
                              child: Text('导出 MP4'),
                            ),
                          if (task.state == MediaTaskState.downloading)
                            const PopupMenuItem(
                              value: 'pause',
                              child: Text('暂停下载'),
                            ),
                          if (task.state == MediaTaskState.paused)
                            const PopupMenuItem(
                              value: 'pause',
                              child: Text('继续下载'),
                            ),
                          if (task.state == MediaTaskState.downloading ||
                              task.state == MediaTaskState.paused)
                            const PopupMenuItem(
                              value: 'cancel',
                              child: Text('取消下载'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除任务'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (task.state == MediaTaskState.downloading ||
                      task.state == MediaTaskState.paused)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      child: LinearProgressIndicator(
                        value: _taskProgress(task),
                        minHeight: 4,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: SiteLensMetrics.itemGap),
          ],
          if (busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }

  double? _taskProgress(MediaTask task) {
    final total = task.totalBytes;
    if (total == null || total <= 0) return null;
    return (task.bytesDownloaded / total).clamp(0, 1).toDouble();
  }

  String _taskProgressLabel(MediaTask task) {
    final progress = _taskProgress(task);
    if (progress == null) return '${task.bytesDownloaded} bytes';
    return '${(progress * 100).round()}% · ${task.bytesDownloaded}/${task.totalBytes} bytes';
  }

  String _taskTitle(MediaTask task, MediaCandidate? candidate) {
    final title = candidate?.title.trim();
    if (title != null && title.isNotEmpty) return title;
    return task.id;
  }
}

class _TaskThumbnail extends StatelessWidget {
  const _TaskThumbnail({required this.task, this.candidate});
  final MediaTask task;
  final MediaCandidate? candidate;

  @override
  Widget build(BuildContext context) {
    final thumbnail = candidate?.thumbnailUrl;
    if (thumbnail == null) {
      return Icon(
        task.state == MediaTaskState.playable
            ? Icons.play_circle
            : Icons.downloading,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        thumbnail.toString(),
        width: 64,
        height: 42,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}
