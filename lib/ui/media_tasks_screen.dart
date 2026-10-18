import 'dart:async';
import 'dart:io';
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

enum _VideoFitMode { contain, cover, fill }

const _playbackSpeeds = <double>[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4, 8];

String _speedLabel(double speed) =>
    speed == speed.roundToDouble() ? '${speed.round()}x' : '${speed}x';

int mediaGestureSeekTarget({
  required int positionMs,
  required int durationMs,
  required double deltaPx,
  required double viewportWidth,
}) {
  if (viewportWidth <= 0 || durationMs <= 0) return positionMs;
  final delta = (deltaPx / viewportWidth * durationMs).round();
  return (positionMs + delta).clamp(0, durationMs).toInt();
}

String _mediaTaskStateLabel(MediaTaskState state) => switch (state) {
  MediaTaskState.queued => '排队中',
  MediaTaskState.downloading => '下载中',
  MediaTaskState.paused => '已暂停',
  MediaTaskState.completed => '已完成',
  MediaTaskState.playable => '可播放',
  MediaTaskState.cancelled => '已取消',
  MediaTaskState.failed => '失败',
  MediaTaskState.reauthorize => '需要重新授权',
};

String _mediaErrorLabel(String? code) => switch (code) {
  null || '' => '',
  MediaErrorCode.staleGeneration => '页面已更新，请重新嗅探',
  MediaErrorCode.invalidUrl => '媒体地址无效',
  MediaErrorCode.unsupported => '暂不支持此媒体格式',
  MediaErrorCode.authorizationRequired => '需要重新授权后下载',
  MediaErrorCode.diskFull => '存储空间不足',
  MediaErrorCode.network => '网络连接失败',
  MediaErrorCode.cancelled => '已取消',
  MediaErrorCode.relayDenied => '媒体中继未获授权',
  _ => '下载失败，可重试',
};

String _taskErrorLabel(MediaTask task) {
  final reason = task.errorReason?.trim();
  if (reason != null && reason.isNotEmpty) return reason;
  return _mediaErrorLabel(task.errorCode);
}

String _shortMediaName(String value) {
  final runes = value.runes.toList();
  if (runes.length <= 13) return value;
  return '${String.fromCharCodes(runes.take(8))}…${String.fromCharCodes(runes.skip(runes.length - 5))}';
}

/// In-app surface for the native Media3 texture. The route keeps the texture
/// and controls visible until the user leaves it, including while a stream is
/// buffering or reports a decoder error.
class NativeMediaPlayerScreen extends StatefulWidget {
  const NativeMediaPlayerScreen({
    super.key,
    required this.app,
    required this.session,
    this.playlist = const [],
    this.playlistIndex = 0,
  });

  final AppController app;
  final NativePlaybackSession session;
  final List<MediaTask> playlist;
  final int playlistIndex;

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
  int _rotationQuarterTurns = 0;
  _VideoFitMode _fitMode = _VideoFitMode.contain;
  bool _closing = false;
  Timer? _gestureHintTimer;
  String? _gestureHint;
  double _brightness = 0.5;
  double _volume = 0.5;
  double _horizontalDelta = 0;
  double _verticalStart = 0;
  double _verticalValue = 0.5;
  bool _verticalLeft = true;
  bool _longPressing = false;
  double _speedBeforeLongPress = 1;
  late int _playlistIndex;

  bool get _canControl =>
      !_closing &&
      _session.state != NativePlaybackState.stopped &&
      _session.state != NativePlaybackState.failed;

  @override
  void initState() {
    super.initState();
    _playlistIndex = widget.playlistIndex;
    _states = widget.app.nativeMedia.states.listen((next) {
      if (!mounted || next.id != _session.id) return;
      setState(() => _session = next);
      _scheduleHide();
    });
    _statePoller = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_refreshState()),
    );
    unawaited(_loadGestureLevels());
    unawaited(_applySystemUi());
    _scheduleHide();
  }

  Future<void> _loadGestureLevels() async {
    try {
      final levels = await widget.app.nativeMedia.levels();
      if (!mounted) return;
      setState(() {
        _brightness = levels.brightness;
        _volume = levels.volume;
      });
    } catch (_) {
      // Brightness/volume gestures remain optional on unsupported platforms.
    }
  }

  void _showGestureHint(String text) {
    if (!mounted) return;
    _gestureHintTimer?.cancel();
    setState(() => _gestureHint = text);
    _gestureHintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _gestureHint = null);
    });
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
        unawaited(_applySystemUi());
      }
    });
  }

  void _toggleControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = !_controlsVisible);
    unawaited(_applySystemUi());
    _scheduleHide();
  }

  void _onDoubleTap() {
    if (!_canControl) return;
    unawaited(
      _command(
        _session.state == NativePlaybackState.playing
            ? () => widget.app.nativeMedia.pause(sessionId: _session.id)
            : () => widget.app.nativeMedia.play(sessionId: _session.id),
      ),
    );
  }

  void _onHorizontalDragStart(DragStartDetails _) {
    _horizontalDelta = 0;
    _hideTimer?.cancel();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_canControl) return;
    _horizontalDelta += details.primaryDelta ?? 0;
    final target = mediaGestureSeekTarget(
      positionMs: _session.positionMs,
      durationMs: _session.durationMs,
      deltaPx: _horizontalDelta,
      viewportWidth: MediaQuery.sizeOf(context).width,
    );
    _showGestureHint(
      '${_horizontalDelta >= 0 ? '快进' : '快退'} ${formatMediaDuration(target)}',
    );
  }

  void _onHorizontalDragEnd(DragEndDetails _) {
    if (!_canControl) return;
    final target = mediaGestureSeekTarget(
      positionMs: _session.positionMs,
      durationMs: _session.durationMs,
      deltaPx: _horizontalDelta,
      viewportWidth: MediaQuery.sizeOf(context).width,
    );
    _horizontalDelta = 0;
    unawaited(_seekTo(target.toDouble()));
    _scheduleHide();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _verticalLeft =
        details.localPosition.dx < MediaQuery.sizeOf(context).width / 2;
    _verticalStart = details.localPosition.dy;
    _verticalValue = _verticalLeft ? _brightness : _volume;
    _hideTimer?.cancel();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_canControl) return;
    final distance = _verticalStart - details.localPosition.dy;
    final value =
        (_verticalValue + distance / MediaQuery.sizeOf(context).height).clamp(
          0.0,
          1.0,
        );
    if (_verticalLeft) {
      _brightness = value;
      _showGestureHint('亮度 ${(value * 100).round()}%');
      unawaited(_setBrightness(value));
    } else {
      _volume = value;
      _showGestureHint('音量 ${(value * 100).round()}%');
      unawaited(_setVolume(value));
    }
  }

  Future<void> _setBrightness(double value) async {
    try {
      final levels = await widget.app.nativeMedia.setBrightness(value);
      if (mounted) setState(() => _brightness = levels.brightness);
    } catch (_) {
      _showGestureHint('当前设备不支持亮度调节');
    }
  }

  Future<void> _setVolume(double value) async {
    try {
      final levels = await widget.app.nativeMedia.setVolume(value);
      if (mounted) setState(() => _volume = levels.volume);
    } catch (_) {
      _showGestureHint('当前设备不支持音量调节');
    }
  }

  void _onLongPressStart(LongPressStartDetails _) {
    if (!_canControl || _longPressing) return;
    _longPressing = true;
    _speedBeforeLongPress = _session.speed;
    unawaited(_setSpeed(2));
    _showGestureHint('2x');
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (!_longPressing) return;
    _longPressing = false;
    unawaited(_setSpeed(_speedBeforeLongPress));
    _showGestureHint(_speedLabel(_speedBeforeLongPress));
  }

  Future<void> _applySystemUi() => SystemChrome.setEnabledSystemUIMode(
    !_controlsVisible ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
  );

  Future<void> _command(Future<NativePlaybackSession> Function() action) async {
    if (!_canControl) return;
    try {
      final next = await action();
      if (!mounted || next.id != _session.id) return;
      setState(() => _session = next);
      _scheduleHide();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放器操作失败：${friendlyError(error)}')),
        );
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

  void _rotateVideo() {
    if (!mounted) return;
    setState(() => _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4);
    _scheduleHide();
  }

  Future<void> _setSpeed(double speed) async {
    await _command(
      () => widget.app.nativeMedia.setSpeed(speed, sessionId: _session.id),
    );
  }

  Future<NativePlaybackSession> _openPlaylistTask(MediaTask task) async {
    final cached = await widget.app.mediaTasks.cachedFile(task.id);
    if (cached != null) {
      return widget.app.nativeMedia.openLocal(task, cached);
    }
    final candidate = await widget.app.db.mediaCandidate(task.candidateId);
    if (candidate == null) throw StateError('下一集媒体候选已不存在');
    return widget.app.nativeMedia.open(
      candidate,
      hostId: task.hostId,
      generation: task.generation,
      sourceUrl: task.sourceUrl,
      sessionId: 'play_${task.id}',
    );
  }

  Future<void> _switchPlaylist(int offset) async {
    if (!_canControl || widget.playlist.isEmpty) return;
    final targetIndex = _playlistIndex + offset;
    if (targetIndex < 0 || targetIndex >= widget.playlist.length) return;
    try {
      final next = await _openPlaylistTask(widget.playlist[targetIndex]);
      if (!mounted) return;
      setState(() {
        _session = next;
        _playlistIndex = targetIndex;
      });
      _showGestureHint(widget.playlist[targetIndex].displayName);
      _scheduleHide();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Widget _videoViewport() => LayoutBuilder(
    builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;
      final maxHeight = constraints.maxHeight;
      final quarterTurn = _rotationQuarterTurns.isOdd;
      final visualWidth = quarterTurn ? maxHeight : maxWidth;
      final visualHeight = quarterTurn ? maxWidth : maxHeight;
      final sourceRatio = _session.videoWidth > 0 && _session.videoHeight > 0
          ? _session.videoWidth / _session.videoHeight
          : 16 / 9;
      var fittedWidth = visualWidth;
      var fittedHeight = visualHeight;
      if (_fitMode == _VideoFitMode.contain) {
        if (visualWidth / visualHeight > sourceRatio) {
          fittedWidth = visualHeight * sourceRatio;
        } else {
          fittedHeight = visualWidth / sourceRatio;
        }
      } else if (_fitMode == _VideoFitMode.cover) {
        if (visualWidth / visualHeight > sourceRatio) {
          fittedHeight = visualWidth / sourceRatio;
        } else {
          fittedWidth = visualHeight * sourceRatio;
        }
      }
      final width = quarterTurn ? fittedHeight : fittedWidth;
      final height = quarterTurn ? fittedWidth : fittedHeight;
      return ClipRect(
        child: Center(
          child: RotatedBox(
            quarterTurns: _rotationQuarterTurns,
            child: SizedBox(
              width: width,
              height: height,
              child: _session.textureId == null
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : Texture(textureId: _session.textureId!),
            ),
          ),
        ),
      );
    },
  );

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _hideTimer?.cancel();
    try {
      await widget.app.nativeMedia.close(sessionId: _session.id);
    } catch (_) {}
  }

  Future<void> _stopAndExit() async {
    if (_closing) return;
    _closing = true;
    _hideTimer?.cancel();
    try {
      await widget.app.nativeMedia.stop(sessionId: _session.id);
    } catch (error) {
      if (mounted) showError(context, error);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _states?.cancel();
    _hideTimer?.cancel();
    _gestureHintTimer?.cancel();
    _statePoller?.cancel();
    unawaited(SystemChrome.setPreferredOrientations([]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
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
              onDoubleTap: _onDoubleTap,
              onHorizontalDragStart: _onHorizontalDragStart,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              onVerticalDragStart: _onVerticalDragStart,
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onLongPressStart: _onLongPressStart,
              onLongPressEnd: _onLongPressEnd,
              child: _videoViewport(),
            ),
            if (_gestureHint != null)
              Center(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      child: Text(
                        _gestureHint!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '旋转 ${(_rotationQuarterTurns + 1) * 90}°',
                          color: Colors.white,
                          icon: const Icon(Icons.screen_rotation_alt),
                          onPressed: _rotateVideo,
                        ),
                        PopupMenuButton<_VideoFitMode>(
                          tooltip: '画面缩放',
                          icon: const Icon(
                            Icons.fit_screen,
                            color: Colors.white,
                          ),
                          initialValue: _fitMode,
                          onSelected: (value) {
                            setState(() => _fitMode = value);
                            _scheduleHide();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: _VideoFitMode.contain,
                              child: Text('自适应比例'),
                            ),
                            PopupMenuItem(
                              value: _VideoFitMode.cover,
                              child: Text('填充画面'),
                            ),
                            PopupMenuItem(
                              value: _VideoFitMode.fill,
                              child: Text('拉伸填满'),
                            ),
                          ],
                        ),
                        PopupMenuButton<double>(
                          tooltip: '播放速度 ${_speedLabel(_session.speed)}',
                          icon: const Icon(Icons.speed, color: Colors.white),
                          initialValue: _playbackSpeeds.contains(_session.speed)
                              ? _session.speed
                              : null,
                          onSelected: _setSpeed,
                          itemBuilder: (_) => [
                            for (final speed in _playbackSpeeds)
                              PopupMenuItem(
                                value: speed,
                                child: Text(_speedLabel(speed)),
                              ),
                          ],
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
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatMediaDuration(_session.positionMs),
                            style: const TextStyle(
                              color: Colors.white,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          Text(
                            formatMediaDuration(_session.durationMs),
                            style: const TextStyle(
                              color: Colors.white,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
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
                              videoWidth: _session.videoWidth,
                              videoHeight: _session.videoHeight,
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
                          tooltip: '上一集',
                          color: Colors.white,
                          icon: const Icon(Icons.skip_previous),
                          onPressed: _playlistIndex > 0
                              ? () => _switchPlaylist(-1)
                              : null,
                        ),
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
                          tooltip: '下一集',
                          color: Colors.white,
                          icon: const Icon(Icons.skip_next),
                          onPressed: _playlistIndex < widget.playlist.length - 1
                              ? () => _switchPlaylist(1)
                              : null,
                        ),
                        IconButton(
                          tooltip: '停止',
                          color: Colors.white,
                          icon: const Icon(Icons.stop_circle_outlined),
                          onPressed: _canControl ? _stopAndExit : null,
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

class MediaManagementScreen extends StatelessWidget {
  const MediaManagementScreen({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => SiteLensPageScaffold(
    title: '媒体管理',
    body: ListView(
      padding: const EdgeInsets.fromLTRB(
        SiteLensMetrics.pagePadding,
        12,
        SiteLensMetrics.pagePadding,
        32,
      ),
      children: [
        SiteLensPanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SiteLensActionRow(
                icon: Icons.download_for_offline_outlined,
                title: '媒体任务',
                subtitle: '查看后台下载、播放和导出状态',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MediaTasksScreen(app: app),
                  ),
                ),
              ),
              const Divider(height: 1, indent: 18, endIndent: 18),
              SwitchListTile(
                title: const Text('下载完成自动转 MP4'),
                subtitle: const Text('仅适用于已缓存的 HLS 视频，失败时保留原始清单'),
                value: app.autoConvertToMp4,
                onChanged: (value) =>
                    safely(context, () => app.setAutoConvertToMp4(value)),
              ),
            ],
          ),
        ),
      ],
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
  Timer? _poller;
  bool _polling = false;
  StreamSubscription<NativePlaybackSession>? _mediaStates;
  final _operations = <String>{};
  bool _selectionMode = false;
  final _selectedTaskIds = <String>{};

  @override
  void initState() {
    super.initState();
    _mediaStates = widget.app.nativeMedia.states.listen((_) {
      if (mounted) setState(() {});
    });
    if (widget.app.nativeDownloads != null) {
      _poller = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_pollNativeTasks());
      });
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    _mediaStates?.cancel();
    super.dispose();
  }

  Future<void> _pollNativeTasks() async {
    if (!mounted || _polling) return;
    _polling = true;
    try {
      for (final task in widget.app.mediaTasks.tasks) {
        if (_operations.contains(task.id)) continue;
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

  Future<void> _run(Future<void> Function() action, {String? taskId}) async {
    final key = taskId ?? '__global__';
    if (!_operations.add(key)) return;
    await safely(context, action);
    _operations.remove(key);
    if (mounted) setState(() {});
  }

  bool _taskBusy(String taskId) => _operations.contains(taskId);

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
    final playlist = mediaPlaylistForTasks(widget.app.mediaTasks.tasks, task);
    final playlistIndex = playlist.indexWhere((item) => item.id == task.id);
    final cached = await widget.app.mediaTasks.cachedFile(task.id);
    if (cached != null) {
      final session = await widget.app.nativeMedia.openLocal(task, cached);
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => NativeMediaPlayerScreen(
              app: widget.app,
              session: session,
              playlist: playlist,
              playlistIndex: playlistIndex < 0 ? 0 : playlistIndex,
            ),
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
        builder: (_) => NativeMediaPlayerScreen(
          app: widget.app,
          session: session,
          playlist: playlist,
          playlistIndex: playlistIndex < 0 ? 0 : playlistIndex,
        ),
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

  Future<void> _retry(MediaTask task, MediaCandidate? candidate) async {
    final resolved =
        candidate ?? await widget.app.db.mediaCandidate(task.candidateId);
    if (resolved == null) throw StateError('媒体候选已不存在');
    if (task.state == MediaTaskState.paused) {
      await _togglePause(task);
    } else if (task.state == MediaTaskState.failed &&
        widget.app.nativeDownloads != null &&
        !resolved.isHls) {
      await widget.app.mediaDownloads.resumeNative(task.id, resolved);
    } else {
      await widget.app.mediaDownloads.startNative(task, resolved);
    }
    if (mounted) {
      showShortToast(context, '已开始续传');
      setState(() {});
    }
  }

  Future<void> _showDetails(MediaTask task, MediaCandidate? candidate) async {
    final resolved =
        candidate ?? await widget.app.db.mediaCandidate(task.candidateId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('媒体详情', style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 12),
              _MediaDetailRow(label: '标题', value: _taskTitle(task, resolved)),
              _MediaDetailRow(
                label: '状态',
                value: _mediaTaskStateLabel(task.state),
              ),
              _MediaDetailRow(
                label: '文件大小',
                value: task.totalBytes == null
                    ? formatBytes(task.bytesDownloaded)
                    : '${formatBytes(task.bytesDownloaded)} / ${formatBytes(task.totalBytes!)}',
              ),
              if (_taskErrorLabel(task).isNotEmpty)
                _MediaDetailRow(label: '错误原因', value: _taskErrorLabel(task)),
              if (resolved != null)
                _MediaDetailRow(label: '格式', value: resolved.effectiveMime),
              if (resolved != null)
                _MediaDetailRow(
                  label: '媒体地址',
                  value: resolved.mediaUrl.toString(),
                ),
              _MediaDetailRow(label: '来源页面', value: task.sourceUrl.toString()),
              if (task.localRef != null)
                _MediaDetailRow(label: '本地缓存', value: task.localRef!),
            ],
          ),
        ),
      ),
    );
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

  bool _isBatchExportable(MediaTask task) =>
      task.state == MediaTaskState.completed ||
      task.state == MediaTaskState.playable;

  String _exportFileName(MediaTask task) {
    final raw = task.displayName.trim().isEmpty ? task.id : task.displayName;
    final safe = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    return '${safe.isEmpty ? task.id : safe}.mp4';
  }

  Future<void> _batchExport() async {
    final selected = widget.app.mediaTasks.tasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .where(_isBatchExportable)
        .toList();
    if (selected.isEmpty) {
      showShortToast(context, '没有可导出的任务');
      return;
    }
    final directoryPath = Platform.isAndroid && widget.app.nativeExports != null
        ? await widget.app.nativeExports!.pickDirectory()
        : await FilePicker.getDirectoryPath(dialogTitle: '选择导出目录');
    if (directoryPath == null || directoryPath.isEmpty) return;
    final directoryUri = Uri.tryParse(directoryPath);
    final isSafDirectory =
        Platform.isAndroid && directoryUri?.scheme == 'content';
    final directory = isSafDirectory ? null : Directory(directoryPath);
    if (directory != null) await directory.create(recursive: true);
    var exported = 0;
    var failed = 0;
    for (final task in selected) {
      try {
        final file = await widget.app.mediaTasks.cachedFile(task.id);
        if (file == null) throw StateError('缓存文件不存在');
        final fileName = _exportFileName(task);
        Future<void> deliver(String source) async {
          if (isSafDirectory) {
            final native = widget.app.nativeExports;
            if (native == null || directoryUri == null) {
              throw StateError('系统目录不可写，请重新选择目录');
            }
            await native.deliverToDirectory(
              source: source,
              directory: directoryUri,
              fileName: fileName,
            );
          } else {
            final destination = File(
              '${directory!.path}${Platform.pathSeparator}$fileName',
            );
            await destination.parent.create(recursive: true);
            await File(source).copy(destination.path);
          }
        }

        if (file.path.toLowerCase().endsWith('.m3u8')) {
          final input = await const HlsPlaylistParser().parseFile(file.uri);
          final result = await widget.app.mediaExports.export(task.id, input);
          if (result.state != ExportState.deliverable ||
              result.outputPath == null) {
            throw StateError(result.errorCode ?? '导出失败');
          }
          await deliver(result.outputPath!);
        } else {
          await deliver(file.path);
        }
        exported++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    _selectionMode = false;
    _selectedTaskIds.clear();
    showShortToast(
      context,
      failed == 0 ? '已导出 $exported 个' : '已导出 $exported 个，$failed 个失败',
    );
    setState(() {});
  }

  void _toggleSelection(String taskId) {
    setState(() {
      if (!_selectedTaskIds.add(taskId)) _selectedTaskIds.remove(taskId);
    });
  }

  void _selectAll(List<MediaTask> tasks) {
    setState(() {
      _selectedTaskIds
        ..clear()
        ..addAll(tasks.where(_isBatchExportable).map((task) => task.id));
    });
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.app.mediaTasks.tasks;
    final activePlayback = widget.app.nativeMedia.active;
    return SiteLensPageScaffold(
      title: _selectionMode ? '已选 ${_selectedTaskIds.length} 项' : '媒体任务',
      actions: [
        if (!_selectionMode)
          IconButton(
            tooltip: '选择任务',
            icon: const Icon(Icons.checklist),
            onPressed: () => setState(() => _selectionMode = true),
          )
        else ...[
          IconButton(
            tooltip: '全选',
            icon: const Icon(Icons.select_all),
            onPressed: () => _selectAll(tasks),
          ),
          IconButton(
            tooltip: '批量导出',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _selectedTaskIds.isEmpty ? null : _batchExport,
          ),
          IconButton(
            tooltip: '退出选择',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _selectionMode = false;
              _selectedTaskIds.clear();
            }),
          ),
        ],
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          12,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          if (activePlayback != null)
            SiteLensPanel(
              child: Row(
                children: [
                  const Icon(Icons.play_circle_filled),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '原生播放：${_mediaTaskStateLabel(_nativeStateAsTaskState(activePlayback.state))}',
                    ),
                  ),
                  IconButton(
                    tooltip: activePlayback.state == NativePlaybackState.playing
                        ? '暂停'
                        : '播放',
                    icon: Icon(
                      activePlayback.state == NativePlaybackState.playing
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () => _run(() async {
                      if (activePlayback.state == NativePlaybackState.playing) {
                        await widget.app.nativeMedia.pause(
                          sessionId: activePlayback.id,
                        );
                      } else {
                        await widget.app.nativeMedia.play(
                          sessionId: activePlayback.id,
                        );
                      }
                      if (mounted) setState(() {});
                    }, taskId: activePlayback.id),
                  ),
                  IconButton(
                    tooltip: '停止',
                    icon: const Icon(Icons.stop),
                    onPressed: () => _run(() async {
                      await widget.app.nativeMedia.stop(
                        sessionId: activePlayback.id,
                      );
                      if (mounted) setState(() {});
                    }, taskId: activePlayback.id),
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
                      leading: _selectionMode
                          ? Checkbox(
                              value: _selectedTaskIds.contains(task.id),
                              onChanged: _isBatchExportable(task)
                                  ? (_) => _toggleSelection(task.id)
                                  : null,
                            )
                          : _TaskThumbnail(
                              task: task,
                              candidate: snapshot.data,
                            ),
                      title: Text(
                        _taskTitle(task, snapshot.data),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_mediaTaskStateLabel(task.state)} · ${_taskProgressLabel(task)}${_taskErrorLabel(task).isEmpty ? '' : ' · ${_taskErrorLabel(task)}'}',
                      ),
                      onTap: _selectionMode
                          ? (_isBatchExportable(task)
                                ? () => _toggleSelection(task.id)
                                : null)
                          : task.state == MediaTaskState.playable
                          ? () => unawaited(
                              _run(() => _play(task), taskId: task.id),
                            )
                          : null,
                      trailing: _selectionMode
                          ? Text(
                              _isBatchExportable(task) ? '可导出' : '未完成',
                              style: Theme.of(context).textTheme.bodySmall,
                            )
                          : PopupMenuButton<String>(
                              enabled: !_taskBusy(task.id),
                              onSelected: (value) {
                                switch (value) {
                                  case 'refresh':
                                    unawaited(
                                      _run(
                                        () => _refreshNative(task),
                                        taskId: task.id,
                                      ),
                                    );
                                  case 'details':
                                    unawaited(
                                      _showDetails(task, snapshot.data),
                                    );
                                  case 'play':
                                    unawaited(
                                      _run(() => _play(task), taskId: task.id),
                                    );
                                  case 'cast':
                                    unawaited(
                                      _run(() => _cast(task), taskId: task.id),
                                    );
                                  case 'export':
                                    unawaited(
                                      _run(
                                        () => _export(task),
                                        taskId: task.id,
                                      ),
                                    );
                                  case 'cancel':
                                    unawaited(
                                      _run(() async {
                                        final native =
                                            widget.app.nativeDownloads;
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
                                      }, taskId: task.id),
                                    );
                                  case 'pause':
                                    unawaited(
                                      _run(
                                        () => _togglePause(task),
                                        taskId: task.id,
                                      ),
                                    );
                                  case 'retry':
                                    unawaited(
                                      _run(
                                        () => _retry(task, snapshot.data),
                                        taskId: task.id,
                                      ),
                                    );
                                  case 'delete':
                                    unawaited(
                                      _run(() async {
                                        final native =
                                            widget.app.nativeDownloads;
                                        if (native != null) {
                                          await native.delete(task.id);
                                        }
                                        await widget.app.mediaTasks.delete(
                                          task.id,
                                        );
                                        if (mounted) setState(() {});
                                      }, taskId: task.id),
                                    );
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'refresh',
                                  child: Text('刷新后台状态'),
                                ),
                                const PopupMenuItem(
                                  value: 'details',
                                  child: Text('查看详情'),
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
                                if (task.state == MediaTaskState.failed ||
                                    task.state == MediaTaskState.cancelled)
                                  const PopupMenuItem(
                                    value: 'retry',
                                    child: Text('重试下载'),
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
    if (progress == null) return formatBytes(task.bytesDownloaded);
    return '${(progress * 100).round()}% · ${formatBytes(task.bytesDownloaded)}/${formatBytes(task.totalBytes!)}';
  }

  String _taskTitle(MediaTask task, MediaCandidate? candidate) {
    final frozen = task.displayName.trim();
    if (frozen.isNotEmpty) return _shortMediaName(frozen);
    final title = candidate?.title.trim();
    if (title != null && title.isNotEmpty) return _shortMediaName(title);
    final segments = candidate?.mediaUrl.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final filename = segments == null || segments.isEmpty
        ? null
        : segments.last;
    return _shortMediaName(
      filename == null || filename.isEmpty ? task.id : filename,
    );
  }
}

MediaTaskState _nativeStateAsTaskState(NativePlaybackState state) =>
    switch (state) {
      NativePlaybackState.preparing => MediaTaskState.downloading,
      NativePlaybackState.playing => MediaTaskState.playable,
      NativePlaybackState.paused => MediaTaskState.paused,
      NativePlaybackState.buffering => MediaTaskState.downloading,
      NativePlaybackState.completed => MediaTaskState.completed,
      NativePlaybackState.stopped => MediaTaskState.cancelled,
      NativePlaybackState.failed => MediaTaskState.failed,
    };

class _MediaDetailRow extends StatelessWidget {
  const _MediaDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
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
