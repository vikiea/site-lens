import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/error_log.dart';
import '../domain/models.dart';
import '../domain/media_artifact_identity.dart';
import '../media/media_service.dart';
import '../media/media_library.dart';
import '../media/media_organization.dart';
import '../media/media_storage.dart';
import '../settings/app_settings.dart';
import 'app_controller.dart';
import 'dlna_cast_screen.dart';
import 'glass_surface.dart';
import 'help_notice.dart';
import 'media_thumbnail.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';
import 'app_theme.dart';
import 'player_gestures_screen.dart';
import 'navigation_observer.dart';
import 'media_browser.dart';

enum _VideoFitMode { contain, cover, fill }

enum _MediaBatchAction { retry, refresh, export, delete }

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

int mediaGestureEpisodeOffset({
  required double deltaPx,
  required double thresholdPx,
}) {
  if (thresholdPx <= 0 || deltaPx.abs() < thresholdPx) return 0;
  // [deltaPx] is startY - currentY: positive means an upward swipe.
  return deltaPx < 0 ? -1 : 1;
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

String readableMediaLocation(String value) {
  final raw = value.trim();
  final uri = Uri.tryParse(raw);
  if (uri?.scheme == 'content') {
    final segments = uri!.pathSegments;
    final decoded = segments.isEmpty ? raw : segments.last;
    final separator = decoded.indexOf(':');
    if (separator > 0) {
      final volume = decoded.substring(0, separator);
      final path = decoded.substring(separator + 1).replaceAll('\\', '/');
      final label = volume == 'primary' ? '内部存储' : volume;
      return path.isEmpty ? label : '$label/$path';
    }
    return decoded;
  }
  final path = uri?.scheme == 'file' ? uri!.toFilePath() : raw;
  return path
      .replaceFirst(RegExp(r'^/storage/emulated/0(?=/|$)'), '内部存储')
      .replaceFirst(RegExp(r'^/sdcard(?=/|$)'), '内部存储');
}

/// In-app surface for the native Media3 texture. The route keeps the texture
/// and controls visible until the user leaves it, including while a stream is
/// buffering or reports a decoder error.
class NativeMediaPlayerScreen extends StatefulWidget {
  const NativeMediaPlayerScreen({
    super.key,
    required this.app,
    required this.session,
    this.task,
    this.candidate,
    this.playlist = const [],
    this.playlistIndex = 0,
    this.preferExported = false,
  });

  final AppController app;
  final NativePlaybackSession session;
  final MediaTask? task;
  final MediaCandidate? candidate;
  final List<MediaTask> playlist;
  final int playlistIndex;
  final bool preferExported;

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
  double _verticalDelta = 0;
  double _verticalValue = 0.5;
  bool _verticalLeft = true;
  bool _longPressing = false;
  double _speedBeforeLongPress = 1;
  late int _playlistIndex;
  final _playlistRetained = <String>{};

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
    _verticalDelta = 0;
    _hideTimer?.cancel();
    if (widget.app.playerVerticalGesture ==
        PlayerVerticalGestureMode.episodeSwitch) {
      return;
    }
    _verticalValue = _verticalLeft ? _brightness : _volume;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_canControl) return;
    final distance = _verticalStart - details.localPosition.dy;
    _verticalDelta = distance;
    if (widget.app.playerVerticalGesture ==
        PlayerVerticalGestureMode.episodeSwitch) {
      final offset = distance < 0 ? -1 : 1;
      final boundary = mediaPlaylistBoundaryHint(
        index: _playlistIndex,
        length: widget.playlist.length,
        offset: offset,
      );
      _showGestureHint(
        distance.abs() < 24
            ? '上下滑动切换集数'
            : widget.playlist.isEmpty
            ? '当前没有可切换的集数'
            : boundary ?? (distance < 0 ? '上一集' : '下一集'),
      );
      return;
    }
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

  void _onVerticalDragEnd(DragEndDetails _) {
    if (!_canControl ||
        widget.app.playerVerticalGesture !=
            PlayerVerticalGestureMode.episodeSwitch) {
      _verticalDelta = 0;
      _scheduleHide();
      return;
    }
    final offset = mediaGestureEpisodeOffset(
      deltaPx: _verticalDelta,
      thresholdPx: MediaQuery.sizeOf(context).height * 0.10,
    );
    _verticalDelta = 0;
    if (offset == 0) {
      _showGestureHint('滑动距离太短');
    } else if (widget.playlist.isEmpty) {
      _showGestureHint('当前没有可切换的集数');
    } else {
      unawaited(_switchPlaylist(offset));
    }
    _scheduleHide();
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
    final partial = _isPartialTask;
    final clamped = partial
        ? target.clamp(0, 1 << 62)
        : duration > 0
        ? target.clamp(0, duration)
        : target.clamp(0, 1 << 62);
    if (!await _waitForPartialSeek(clamped)) return;
    await _command(
      () => widget.app.nativeMedia.seek(
        Duration(milliseconds: clamped),
        sessionId: _session.id,
      ),
    );
  }

  Future<void> _seekTo(double value) async {
    final target = _isPartialTask
        ? value.round().clamp(0, 1 << 62)
        : value.round().clamp(0, _session.durationMs);
    if (!await _waitForPartialSeek(target)) return;
    await _command(
      () => widget.app.nativeMedia.seek(
        Duration(milliseconds: target),
        sessionId: _session.id,
      ),
    );
  }

  bool get _isPartialTask {
    final task = widget.task;
    return task != null &&
        (task.state == MediaTaskState.downloading ||
            task.state == MediaTaskState.paused);
  }

  Future<bool> _waitForPartialSeek(int targetMs) async {
    if (!_isPartialTask || widget.task == null) return true;
    widget.app.mediaDownloads.prioritizeHlsSeek(widget.task!.id, targetMs);
    final available = await widget.app.mediaTasks.waitForHlsPosition(
      widget.task!.id,
      targetMs,
    );
    if (!available) {
      _showGestureHint('目标分片尚未缓存，已等待超时');
    }
    return available;
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
    final shouldRetain = !_playlistRetained.contains(task.id);
    var retained = false;
    try {
      if (shouldRetain) {
        widget.app.mediaTasks.retain(task.id);
        _playlistRetained.add(task.id);
        retained = true;
      }
      if (widget.preferExported) {
        final artifact = widget.app.mediaLibrary.item(task.id);
        final uri = Uri.tryParse(artifact?.location ?? '');
        if (uri?.scheme == 'content') {
          return await widget.app.nativeMedia.openDocument(task, uri!);
        }
      }
      final cached =
          await widget.app.mediaPlaybackFile(
            task,
            preferExported: widget.preferExported,
          ) ??
          (!widget.preferExported &&
                  widget.app.allowStreamingWhileDownloading &&
                  (task.state == MediaTaskState.downloading ||
                      task.state == MediaTaskState.paused)
              ? await widget.app.mediaPartialPlaybackFile(task)
              : null);
      if (cached != null) {
        return await widget.app.nativeMedia.openLocal(task, cached);
      }
      throw StateError('文件缺失，请在媒体任务中重新下载');
    } catch (_) {
      if (retained) {
        widget.app.mediaTasks.release(task.id);
        _playlistRetained.remove(task.id);
      }
      rethrow;
    }
  }

  Future<void> _switchPlaylist(int offset) async {
    if (!_canControl || widget.playlist.isEmpty) return;
    final boundary = mediaPlaylistBoundaryHint(
      index: _playlistIndex,
      length: widget.playlist.length,
      offset: offset,
    );
    if (boundary != null) {
      _showGestureHint(boundary);
      return;
    }
    final targetIndex = _playlistIndex + offset;
    try {
      final next = await _openPlaylistTask(widget.playlist[targetIndex]);
      if (!mounted || _closing) {
        await widget.app.nativeMedia.close(sessionId: next.id);
        return;
      }
      setState(() {
        _session = next;
        _playlistIndex = targetIndex;
      });
      _showGestureHint(
        mediaPlaylistEntryName(widget.playlist, widget.playlist[targetIndex]),
      );
      _scheduleHide();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _showPlaylist() async {
    if (!mounted || widget.playlist.isEmpty) {
      _showGestureHint('当前没有播放列表');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
          ),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: widget.playlist.length,
            itemBuilder: (_, index) {
              final task = widget.playlist[index];
              final selected = index == _playlistIndex;
              final colors = SiteLensColors.of(sheetContext);
              return Theme(
                data: siteLensQuietInteractionTheme(sheetContext),
                child: ListTile(
                  selected: selected,
                  focusColor: colors.rowInteractionOverlay,
                  hoverColor: colors.rowInteractionOverlay,
                  splashColor: colors.rowInteractionOverlay,
                  leading: Icon(
                    selected ? Icons.play_circle_filled : Icons.video_file,
                  ),
                  title: SiteLensLeadingEllipsisText(
                    mediaPlaylistEntryName(widget.playlist, task),
                  ),
                  trailing: selected ? const Icon(Icons.check) : null,
                  onTap: selected
                      ? () => Navigator.of(sheetContext).pop()
                      : () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_switchPlaylist(index - _playlistIndex));
                        },
                ),
              );
            },
          ),
        ),
      ),
    );
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

  Future<void> _openCastControls() async {
    if (!_canControl) return;
    final currentTask = widget.playlist.isEmpty
        ? widget.task
        : widget.playlist[_playlistIndex];
    final candidate = widget.candidate;
    if (currentTask == null && candidate == null) {
      _showGestureHint('当前媒体没有可投屏来源');
      return;
    }
    await showDlnaCastControls(
      context,
      widget.app,
      task: currentTask,
      candidate: candidate,
      initialPosition: Duration(milliseconds: _session.positionMs),
      onCastStarted: () async {
        if (_session.state == NativePlaybackState.playing) {
          await widget.app.nativeMedia.pause(sessionId: _session.id);
        }
      },
    );
    if (mounted) setState(() {});
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
    for (final taskId in _playlistRetained) {
      widget.app.mediaTasks.release(taskId);
    }
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
              onVerticalDragEnd: _onVerticalDragEnd,
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
                        IconButton(
                          tooltip: '播放列表',
                          color: Colors.white,
                          icon: const Icon(Icons.queue_music),
                          onPressed: _showPlaylist,
                        ),
                        IconButton(
                          tooltip: 'DLNA 投屏',
                          color: Colors.white,
                          icon: const Icon(Icons.cast_outlined),
                          onPressed:
                              widget.task == null && widget.candidate == null
                              ? null
                              : () => unawaited(_openCastControls()),
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

Future<void> openMediaTaskPlayer(
  BuildContext context,
  AppController app,
  MediaTask task, {
  bool preferExported = false,
}) async {
  app.mediaTasks.retain(task.id);
  final prioritize =
      task.state == MediaTaskState.downloading ||
      task.state == MediaTaskState.paused;
  if (prioritize) app.mediaDownloads.setTaskPriority(task.id, 100);
  try {
    final playlist = mediaPlaylistForTasks(app.mediaTasks.tasks, task);
    final playlistIndex = playlist.indexWhere((item) => item.id == task.id);
    final artifact = preferExported ? app.mediaLibrary.item(task.id) : null;
    final document = Uri.tryParse(artifact?.location ?? '');
    final allowPartial =
        app.allowStreamingWhileDownloading &&
        (task.state == MediaTaskState.downloading ||
            task.state == MediaTaskState.paused);
    final cached = document?.scheme == 'content'
        ? null
        : await app.mediaPlaybackFile(task, preferExported: preferExported) ??
              (preferExported || !allowPartial
                  ? null
                  : await app.mediaPartialPlaybackFile(task));
    if (cached != null || document?.scheme == 'content') {
      final session = document?.scheme == 'content'
          ? await app.nativeMedia.openDocument(task, document!)
          : await app.nativeMedia.openLocal(task, cached!);
      if (!context.mounted) {
        await app.nativeMedia.close(sessionId: session.id);
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: siteLensPlayerRouteName),
          builder: (_) => NativeMediaPlayerScreen(
            app: app,
            session: session,
            task: task,
            playlist: playlist,
            playlistIndex: playlistIndex < 0 ? 0 : playlistIndex,
            preferExported: preferExported,
          ),
        ),
      );
      return;
    }
    throw StateError('文件缺失，请在媒体任务中重新下载');
  } finally {
    if (prioritize) app.mediaDownloads.clearTaskPriority(task.id);
    app.mediaTasks.release(task.id);
  }
}

class MediaLibraryScreen extends StatefulWidget {
  const MediaLibraryScreen({super.key, required this.app});
  final AppController app;

  @override
  State<MediaLibraryScreen> createState() => _MediaLibraryScreenState();
}

class _MediaLibraryScreenState extends State<MediaLibraryScreen> {
  AppController get app => widget.app;
  late final MediaOrganizationService _organization = MediaOrganizationService(
    db: app.db,
    collection: 'library',
  );
  late final MediaBrowserController _browser = MediaBrowserController(
    organization: _organization,
  );
  String? _error;
  bool _scanning = false;
  MediaStorageRoot? _storageRoot;
  final _migrationCandidates = <String>{};
  final _physicalFolders = <String, MediaOrganizationFolder>{};
  List<MediaStorageEntry> _storageEntries = const [];
  String? _physicalRootLocation;
  Future<void>? _storageRefresh;
  Future<void>? _physicalRefresh;

  @override
  void initState() {
    super.initState();
    _organization.addListener(_changed);
    _browser.addListener(_changed);
    app.addListener(_changed);
    app.mediaLibrary.addListener(_libraryChanged);
    unawaited(_refreshStorageState());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _organization.removeListener(_changed);
    _browser.removeListener(_changed);
    app.removeListener(_changed);
    app.mediaLibrary.removeListener(_libraryChanged);
    _browser.dispose();
    _organization.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
    unawaited(_refreshStorageState());
  }

  void _libraryChanged() {
    _changed();
    if (mounted) unawaited(_loadPhysicalDirectory());
  }

  Future<void> _refreshStorageState() {
    return _storageRefresh ??= () async {
      try {
        final root = await app.mediaStorage.resolve();
        final candidates = <String>{};
        if (root.configured && root.available) {
          for (final item in app.mediaLibrary.items) {
            if (await app.mediaStorage.needsMigration(item)) {
              candidates.add(item.taskId);
            }
          }
        }
        if (!mounted) return;
        setState(() {
          _storageRoot = root;
          _migrationCandidates
            ..clear()
            ..addAll(candidates);
        });
      } catch (error) {
        if (mounted) setState(() => _error = friendlyError(error));
      } finally {
        _storageRefresh = null;
      }
    }();
  }

  Future<void> _load() async {
    try {
      await app.mediaLibrary.restore();
      await _organization.restore();
      if (await app.db.setting('mediaLibraryOrganizationMigratedV2') != '1') {
        await _organization.restoreAndSync(
          app.mediaLibrary.items.map(
            (item) => MediaOrganizationSeed(
              itemId: item.taskId,
              legacyFolder: app.mediaLibrary.folderFor(item),
            ),
          ),
        );
      }
      await _loadPhysicalDirectory();
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    }
  }

  Future<void> _rescan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final result = await app.mediaLibrary.rescan(
        directory: app.mp4ExportDirectory,
      );
      await _loadPhysicalDirectory();
      if (!mounted) return;
      showShortToast(
        context,
        result.added == 0
            ? '已扫描 ${result.found} 个 MP4，索引没有新增'
            : '已恢复 ${result.added} 个媒体文件索引',
      );
      if (result.warnings.isNotEmpty) {
        setState(() => _error = result.warnings.join('；'));
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _loadPhysicalDirectory({String? directory}) {
    return _physicalRefresh ??= () async {
      try {
        final root = await app.mediaStorage.resolve();
        final target = directory ?? root.location;
        if (_physicalRootLocation != root.location) {
          _physicalFolders.clear();
          _physicalRootLocation = root.location;
          if (_browser.folderId != null) _browser.goUp();
        }
        final entries = await app.mediaStorage.listDirectory(directory: target);
        final parentId = target == root.location ? null : target;
        for (final entry in entries.where((entry) => entry.directory)) {
          _physicalFolders[entry.location] = MediaOrganizationFolder(
            id: entry.location,
            name: entry.name,
            parentId: parentId,
          );
        }
        if (parentId != null && !_physicalFolders.containsKey(parentId)) {
          _physicalFolders[parentId] = MediaOrganizationFolder(
            id: parentId,
            name: _physicalName(parentId),
          );
        }
        _browser.setPhysicalFolders(_physicalFolders.values);
        if (mounted) {
          setState(() {
            _storageEntries = entries;
            _storageRoot = root;
          });
        }
      } catch (error) {
        if (mounted) setState(() => _error = friendlyError(error));
      } finally {
        _physicalRefresh = null;
      }
    }();
  }

  String _physicalName(String location) {
    final uri = Uri.tryParse(location);
    if (uri?.scheme == 'content') {
      return uri!.pathSegments.lastOrNull ?? '媒体目录';
    }
    return File(location).uri.pathSegments.lastOrNull ?? '媒体目录';
  }

  Future<Map<String, String>> _collectPhysicalFiles(
    String location, {
    String prefix = '',
  }) async {
    final result = <String, String>{};
    final entries = await app.mediaStorage.listDirectory(directory: location);
    for (final entry in entries) {
      final relative = prefix.isEmpty ? entry.name : '$prefix/${entry.name}';
      if (entry.directory) {
        result.addAll(
          await _collectPhysicalFiles(entry.location, prefix: relative),
        );
      } else {
        result[relative] = entry.location;
      }
    }
    return result;
  }

  List<MediaArtifact> _visiblePhysicalItems() {
    final bySource = <String, MediaArtifact>{
      for (final item in app.mediaLibrary.items)
        mediaArtifactSourceKey(item.location): item,
    };
    final result = <MediaArtifact>[];
    for (final entry in _storageEntries.where((entry) => !entry.directory)) {
      final item = bySource[mediaArtifactSourceKey(entry.location)];
      if (item != null) result.add(item);
    }
    if (_browser.folderId == null && _migrationCandidates.isNotEmpty) {
      final present = result.map((item) => item.taskId).toSet();
      result.addAll(
        app.mediaLibrary.items.where(
          (item) =>
              _migrationCandidates.contains(item.taskId) &&
              !present.contains(item.taskId),
        ),
      );
    }
    return result;
  }

  int _physicalFolderItemCount(String folder) {
    final uri = Uri.tryParse(folder);
    if (uri?.scheme == 'content') {
      return app.mediaLibrary.items
          .where((item) => item.location.contains('/document/'))
          .where((item) => item.folder == _physicalName(folder))
          .length;
    }
    final root = p.normalize(folder);
    return app.mediaLibrary.items.where((item) {
      final itemUri = Uri.tryParse(item.location);
      if (itemUri?.scheme == 'content') return false;
      final path = itemUri?.scheme == 'file'
          ? itemUri!.toFilePath()
          : item.location;
      return p.isWithin(root, p.normalize(path));
    }).length;
  }

  MediaBrowserOperations get _operations => MediaBrowserOperations(
    renameItem: (id, name) => app.mediaLibrary.rename(id, name),
    moveItem: (id, folderId) => _organization.moveItems([id], folderId),
    copyItem: (id) async => (await app.mediaLibrary.copy(id)).taskId,
    deleteItem: (id) => app.deleteMediaArtifact(id),
    preflightDelete: (id) async =>
        app.mediaTasks.canDelete(id) ? null : '媒体正在播放、导出或投屏，请先停止',
    preflightCopy: (id) async =>
        app.mediaTasks.canDelete(id) ? null : '媒体正在播放、导出或投屏，请先停止',
  );

  Future<void> _createFolder() async {
    final name = await showMediaBrowserNameDialog(
      context,
      title: '新建文件夹',
      initial: '',
      label: '文件夹名称',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await safely(context, () async {
      final root = await app.mediaStorage.resolve();
      final parent = _browser.folderId ?? root.location;
      await app.mediaStorage.createDirectory(parent: parent, name: name);
      await _loadPhysicalDirectory(directory: parent);
    });
  }

  Future<void> _openPhysicalFolder(String location) async {
    _browser.openFolder(location);
    await _loadPhysicalDirectory(directory: location);
  }

  Future<void> _goUpPhysicalFolder() async {
    final parent = _browser.currentFolder?.parentId;
    _browser.goUp();
    await _loadPhysicalDirectory(directory: parent);
  }

  Future<void> _fileAction(String action, MediaArtifact item) async {
    switch (action) {
      case 'details':
        final task =
            app.mediaTasks.referenceTask(item.taskId) ??
            app.mediaLibrary.presentationTask(item);
        await showMediaTaskDetails(context, app, task, artifact: item);
      case 'play':
        final task =
            app.mediaTasks.referenceTask(item.taskId) ??
            app.mediaLibrary.presentationTask(item);
        await openMediaTaskPlayer(context, app, task, preferExported: true);
      case 'cast':
        final task = app.mediaTasks.task(item.taskId);
        if (task == null) throw StateError('该 MP4 没有对应媒体任务，暂不支持投屏');
        await castMediaTask(context, app, task);
      case 'regenerate':
        final task = app.mediaTasks.task(item.taskId);
        if (task == null) throw StateError('原下载任务已不存在，请重新下载 HLS 后导出');
        await app.exportMediaTask(task, forceRegenerate: true);
        if (mounted) showShortToast(context, 'MP4 已重新导出');
      case 'rename':
        final name = await showMediaBrowserNameDialog(
          context,
          title: '重命名文件',
          initial: item.name.replaceFirst(
            RegExp(r'\.mp4$', caseSensitive: false),
            '',
          ),
          label: '文件名',
          suffix: '.mp4',
        );
        if (name != null && name.trim().isNotEmpty) {
          await app.mediaLibrary.rename(item.taskId, name);
        }
      case 'move':
      case 'movePhysical':
        final directory = await _pickStorageDestination(title: '移动媒体文件到目录');
        if (directory != null) {
          await app.mediaStorage.moveArtifact(item.taskId, directory);
        }
      case 'migrate':
        await app.mediaStorage.migrateArtifact(item.taskId);
        await _refreshStorageState();
      case 'copy':
        final directory = await _pickStorageDestination(title: '复制媒体文件到目录');
        if (directory != null) {
          await app.mediaStorage.copyArtifact(item.taskId, directory);
        }
      case 'reauthorize':
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => MediaManagementScreen(app: app),
          ),
        );
      case 'delete':
        final linkedTask = app.mediaTasks.task(item.taskId);
        var deleteTaskCache = false;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => SiteLensAlertDialog(
              title: const Text('删除媒体文件'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('删除“${item.name}”及其应用播放副本？'),
                  if (linkedTask != null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('同时删除媒体任务及缓存'),
                      subtitle: const Text('默认保留，删除后需要重新下载'),
                      value: deleteTaskCache,
                      onChanged: (value) =>
                          setDialogState(() => deleteTaskCache = value == true),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          ),
        );
        if (confirmed == true) {
          await app.deleteMediaArtifact(
            item.taskId,
            deleteTaskCache: linkedTask != null && deleteTaskCache,
            deleteTask: linkedTask != null && deleteTaskCache,
          );
          await _organization.removeItems([item.taskId]);
        }
    }
  }

  Future<String?> _pickStorageDestination({required String title}) async {
    final root = await app.mediaStorage.resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    final directories = <MediaStorageEntry>[];
    Future<void> collect(String parent, int depth) async {
      if (depth >= 16) return;
      final entries = await app.mediaStorage.listDirectory(directory: parent);
      for (final entry in entries.where((entry) => entry.directory)) {
        directories.add(entry);
        await collect(entry.location, depth + 1);
      }
    }

    await collect(root.location, 0);
    if (!mounted) return null;
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            SiteLensCompactRow(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(title),
              subtitle: const Text('媒体库根目录'),
              onTap: () => Navigator.pop(sheetContext, root.location),
            ),
            for (final entry in directories)
              SiteLensCompactRow(
                leading: const Icon(Icons.folder_outlined),
                title: Text(entry.name),
                subtitle: Text(readableMediaLocation(entry.location)),
                onTap: () => Navigator.pop(sheetContext, entry.location),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _folderAction(
    MediaOrganizationFolder folder,
    String action,
  ) async {
    if (_browser.physicalMode) {
      switch (action) {
        case 'rename':
          final name = await showMediaBrowserNameDialog(
            context,
            title: '重命名目录',
            initial: folder.name,
            label: '目录名称',
          );
          if (name != null && name.trim().isNotEmpty) {
            final before = Uri.tryParse(folder.id)?.scheme == 'content'
                ? await _collectPhysicalFiles(folder.id)
                : const <String, String>{};
            final next = await app.mediaStorage.renameEntry(
              location: folder.id,
              name: name.trim(),
            );
            if (Uri.tryParse(folder.id)?.scheme != 'content') {
              await app.mediaLibrary.rewriteLocalPrefix(folder.id, next);
            } else {
              final after = await _collectPhysicalFiles(next);
              final rewrites = <String, String>{};
              for (final entry in before.entries) {
                final replacement = after[entry.key];
                if (replacement != null) rewrites[entry.value] = replacement;
              }
              await app.mediaLibrary.rewriteLocations(rewrites);
            }
            await _loadPhysicalDirectory(directory: folder.parentId);
          }
        case 'delete':
          final confirmed = await confirmMediaBrowserDelete(
            context,
            title: '删除目录',
            message: '删除“${folder.name}”及其全部媒体文件？',
          );
          if (confirmed) {
            Future<List<MediaStorageEntry>> collectFiles(
              String location,
            ) async {
              final entries = await app.mediaStorage.listDirectory(
                directory: location,
              );
              final files = <MediaStorageEntry>[];
              for (final entry in entries) {
                if (entry.directory) {
                  files.addAll(await collectFiles(entry.location));
                } else {
                  files.add(entry);
                }
              }
              return files;
            }

            for (final child in await collectFiles(folder.id)) {
              final item = app.mediaLibrary.items
                  .where(
                    (candidate) =>
                        mediaArtifactSourceKey(candidate.location) ==
                        mediaArtifactSourceKey(child.location),
                  )
                  .firstOrNull;
              if (item != null) await app.deleteMediaArtifact(item.taskId);
            }
            await app.mediaStorage.deleteEntry(folder.id);
            await _loadPhysicalDirectory(directory: folder.parentId);
          }
      }
      return;
    }
    switch (action) {
      case 'rename':
        final name = await showMediaBrowserNameDialog(
          context,
          title: '重命名文件夹',
          initial: folder.name,
          label: '文件夹名称',
        );
        if (name != null && name.trim().isNotEmpty) {
          await _organization.renameFolder(folder.id, name);
        }
      case 'move':
        final choice = await showMediaBrowserFolderPicker(
          context,
          _organization,
          excludedFolderIds: {
            folder.id,
            ..._organization.descendantsOf(folder.id),
          },
        );
        if (choice.confirmed) {
          await _organization.moveFolder(folder.id, choice.folderId);
        }
      case 'copy':
        final result = await runMediaBrowserFolderCopy(
          context,
          organization: _organization,
          operations: _operations,
          folderId: folder.id,
        );
        if (mounted && result.failed.isNotEmpty) {
          showShortToast(
            context,
            '已复制 ${result.succeeded.length} 项，${result.failed.length} 项失败',
          );
        }
      case 'delete':
        final result = await runMediaBrowserDelete(
          context,
          organization: _organization,
          operations: _operations,
          itemIds: _organization.itemIdsInFolder(folder.id),
          title: '删除文件夹内容',
          message: '删除“${folder.name}”中的所有媒体文件？文件夹会保留。',
        );
        if (mounted && result.failed.isNotEmpty) {
          showShortToast(
            context,
            '已删除 ${result.succeeded.length} 项，${result.failed.length} 项失败',
          );
        }
    }
  }

  Future<void> _batchAction(String action) async {
    if (_browser.busy) return;
    _browser.busy = true;
    _browser.refresh();
    final itemIds = _browser.selectedItemIds.toList();
    final folderIds = _browser.selectedFolderIds.toList();
    try {
      if (_browser.physicalMode) {
        final directory = switch (action) {
          'move' => await _pickStorageDestination(title: '移动媒体文件到目录'),
          'copy' => await _pickStorageDestination(title: '复制媒体文件到目录'),
          _ => null,
        };
        if (action == 'move' && directory != null) {
          for (final id in itemIds) {
            await app.mediaStorage.moveArtifact(id, directory);
          }
        } else if (action == 'copy' && directory != null) {
          for (final id in itemIds) {
            await app.mediaStorage.copyArtifact(id, directory);
          }
        } else if (action == 'delete' && itemIds.isNotEmpty) {
          if (!mounted) return;
          final confirmed = await confirmMediaBrowserDelete(
            context,
            title: '删除选中的媒体',
            message: '删除选中的 ${itemIds.length} 个媒体文件？关联任务缓存会保留。',
          );
          if (confirmed) {
            for (final id in itemIds) {
              await app.deleteMediaArtifact(id);
            }
          }
        }
        return;
      }
      switch (action) {
        case 'move':
          await runMediaBrowserMove(
            context: context,
            organization: _organization,
            itemIds: itemIds,
            folderIds: folderIds,
            currentFolderId: _browser.folderId,
          );
        case 'copy':
          final choice = await showMediaBrowserFolderPicker(
            context,
            _organization,
          );
          if (!mounted || !choice.confirmed) return;
          {
            final result = await runMediaBrowserCopySelection(
              context,
              organization: _organization,
              operations: _operations,
              itemIds: itemIds,
              folderIds: folderIds,
              destination: choice.folderId,
            );
            if (mounted && result.failed.isNotEmpty) {
              showShortToast(
                context,
                '已复制 ${result.succeeded.length} 项，${result.failed.length} 项失败',
              );
            }
          }
        case 'delete':
          final result = await runMediaBrowserDeleteSelection(
            context,
            organization: _organization,
            operations: _operations,
            itemIds: itemIds,
            folderIds: folderIds,
            title: '删除选中的媒体',
            message: '删除选中的 ${itemIds.length} 个媒体文件？已关联任务缓存默认保留。',
          );
          if (mounted && result.failed.isNotEmpty) {
            showShortToast(
              context,
              '已删除 ${result.succeeded.length} 项，${result.failed.length} 项失败',
            );
          }
      }
    } finally {
      _browser.busy = false;
      _browser.refresh();
      if (mounted) _browser.exitSelection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allExports = app.mediaLibrary.items;
    final visible = _browser.physicalMode
        ? _visiblePhysicalItems()
        : allExports
              .where(
                (item) =>
                    _organization.folderFor(item.taskId) == _browser.folderId,
              )
              .toList();
    final folders = _browser.folders;
    final writesEnabled =
        _storageRoot?.permission != MediaStoragePermission.revoked;
    _browser.pruneSelection(
      itemIds: visible.map((item) => item.taskId),
      folderIds: folders.map((folder) => folder.id),
    );
    final current = _browser.currentFolder;
    return SiteLensPageScaffold(
      title: _browser.selectionMode ? '已选 ${_browser.selectedCount} 项' : '媒体',
      actions: [
        if (!_browser.selectionMode) ...[
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: writesEnabled ? _createFolder : null,
          ),
          SiteLensRefreshButton(
            tooltip: '重新扫描媒体文件',
            refreshing: _scanning,
            onPressed: _rescan,
          ),
          if (app.mediaCast.status.active)
            IconButton(
              tooltip: '投屏控制',
              icon: const Icon(Icons.cast_connected),
              onPressed: () => showDlnaCastControls(context, app),
            ),
          IconButton(
            tooltip: '选择媒体',
            icon: const Icon(Icons.checklist),
            onPressed: _browser.enterSelection,
          ),
          IconButton(
            tooltip: '媒体任务',
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MediaTasksScreen(app: app),
              ),
            ),
          ),
        ] else
          MediaBrowserSelectionActions(
            controller: _browser,
            visibleItemIds: visible.map((item) => item.taskId),
            visibleFolderIds: folders.map((folder) => folder.id),
            onAction: (action) => unawaited(_batchAction(action)),
            writesEnabled: writesEnabled,
          ),
      ],
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SiteLensMetrics.pagePadding,
                12,
                SiteLensMetrics.pagePadding,
                0,
              ),
              child: SiteLensErrorBanner(
                text: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SiteLensMetrics.pagePadding,
              12,
              SiteLensMetrics.pagePadding,
              0,
            ),
            child: SiteLensHelpNotice(
              app: app,
              noticeId: 'media.library',
              text: '这里是已导出的 MP4。下载和批量操作请打开“媒体任务”。',
            ),
          ),
          if (_organization.hasStoredOrganization)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SiteLensMetrics.pagePadding,
                8,
                SiteLensMetrics.pagePadding,
                0,
              ),
              child: SiteLensCompactRow(
                leading: const Icon(Icons.auto_fix_high_outlined),
                title: const Text('发现旧媒体分类'),
                subtitle: const Text('打开媒体管理，可将分类迁移为真实目录'),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => MediaManagementScreen(app: app),
                  ),
                ),
              ),
            ),
          Expanded(
            child: SiteLensListPanel(
              scrollKey: const PageStorageKey('media-library-scroll'),
              slivers: [
                if (current != null)
                  SliverToBoxAdapter(
                    child: MediaBrowserFolderRow(
                      folder: current,
                      itemCount: visible.length,
                      parent: true,
                      physical: _browser.physicalMode,
                      onOpen: _browser.physicalMode
                          ? _goUpPhysicalFolder
                          : _browser.goUp,
                      onAction: (_) {},
                    ),
                  ),
                if (folders.isNotEmpty)
                  SliverList.builder(
                    itemCount: folders.length * 2 - 1,
                    itemBuilder: (_, index) {
                      if (index.isOdd) return const SiteLensPanelDivider();
                      final folder = folders[index ~/ 2];
                      return MediaBrowserFolderRow(
                        folder: folder,
                        itemCount: _browser.physicalMode
                            ? _physicalFolderItemCount(folder.id)
                            : _organization.itemIdsInFolder(folder.id).length,
                        physical: _browser.physicalMode,
                        actionsEnabled: writesEnabled,
                        selectionMode: _browser.selectionMode,
                        selected: _browser.selectedFolderIds.contains(
                          folder.id,
                        ),
                        onSelected: (_) => _browser.toggleFolder(folder.id),
                        onOpen: () => _browser.physicalMode
                            ? _openPhysicalFolder(folder.id)
                            : _browser.openFolder(folder.id),
                        onAction: (action) => safely(
                          context,
                          () => _folderAction(folder, action),
                        ),
                      );
                    },
                  ),
                if (visible.isEmpty &&
                    (current != null ||
                        (folders.isEmpty && allExports.isEmpty)))
                  SliverToBoxAdapter(
                    child: SiteLensCompactRow(
                      leading: Icon(
                        current == null
                            ? Icons.video_library_outlined
                            : Icons.folder_open_outlined,
                        size: 18,
                      ),
                      title: Text(current == null ? '暂无导出的 MP4' : '文件夹为空'),
                      subtitle: Text(
                        current == null
                            ? '在媒体任务中完成下载并导出后，媒体会出现在这里；文件仍在目录时可重新扫描。'
                            : '可以移动或复制媒体到这里。',
                      ),
                    ),
                  ),
                if (visible.isNotEmpty)
                  SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (_, index) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MediaLibraryTile(
                          key: ValueKey(visible[index].taskId),
                          app: app,
                          item: visible[index],
                          task: app.mediaLibrary.presentationTask(
                            visible[index],
                          ),
                          showMigration: _migrationCandidates.contains(
                            visible[index].taskId,
                          ),
                          showReauthorize:
                              _storageRoot?.permission ==
                              MediaStoragePermission.revoked,
                          onAction: (action) => safely(
                            context,
                            () => _fileAction(action, visible[index]),
                          ),
                          selectionMode: _browser.selectionMode,
                          selected: _browser.selectedItemIds.contains(
                            visible[index].taskId,
                          ),
                          onSelected: (_) =>
                              _browser.toggleItem(visible[index].taskId),
                        ),
                        if (index < visible.length - 1)
                          const SiteLensPanelDivider(),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaLibraryTile extends StatefulWidget {
  const _MediaLibraryTile({
    super.key,
    required this.app,
    required this.item,
    required this.task,
    required this.onAction,
    this.showMigration = false,
    this.showReauthorize = false,
    this.selectionMode = false,
    this.selected = false,
    this.onSelected,
  });
  final AppController app;
  final MediaArtifact item;
  final MediaTask task;
  final Future<void> Function(String) onAction;
  final bool showMigration;
  final bool showReauthorize;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool?>? onSelected;

  @override
  State<_MediaLibraryTile> createState() => _MediaLibraryTileState();
}

class _MediaLibraryTileState extends State<_MediaLibraryTile> {
  late Future<MediaArtifact> _metadata = widget.app.mediaLibrary.inspect(
    widget.item.taskId,
  );
  late final Future<MediaCandidate?> _candidate = widget.app.db.mediaCandidate(
    widget.task.candidateId,
  );

  @override
  void didUpdateWidget(covariant _MediaLibraryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.location != widget.item.location) {
      _metadata = widget.app.mediaLibrary.inspect(widget.item.taskId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MediaArtifact>(
    future: _metadata,
    builder: (context, snapshot) {
      final item =
          widget.app.mediaLibrary.item(widget.item.taskId) ?? widget.item;
      final thumbnail = item.thumbnailPath;
      final details = <String>[
        'MP4',
        formatBytes(item.size),
        if ((item.durationMs ?? 0) > 0) formatMediaDuration(item.durationMs!),
        if ((item.width ?? 0) > 0 && (item.height ?? 0) > 0)
          '${item.width}×${item.height}',
      ];
      final preview = SizedBox(
        width: 68,
        height: 48,
        child: FutureBuilder<MediaCandidate?>(
          future: _candidate,
          builder: (_, data) {
            final candidateThumbnail = data.data?.thumbnailUrl == null
                ? null
                : NetworkImage(data.data!.thumbnailUrl.toString());
            final localThumbnail =
                thumbnail == null || thumbnail.startsWith('content:')
                ? null
                : FileImage(File(thumbnail));
            return ClipRRect(
              borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
              child: MediaThumbnail(
                image: localThumbnail ?? candidateThumbnail,
                fallbackImage: localThumbnail == null
                    ? null
                    : candidateThumbnail,
              ),
            );
          },
        ),
      );
      return SiteLensCompactRow(
        leading: widget.selectionMode
            ? Checkbox(
                value: widget.selected,
                onChanged: widget.onSelected,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )
            : preview,
        title: SiteLensLeadingEllipsisText(
          item.name.replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), ''),
        ),
        subtitle: Text(
          '${details.join(' · ')}${snapshot.hasError ? ' · 文件暂不可用' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        onTap: widget.selectionMode
            ? () => widget.onSelected?.call(!widget.selected)
            : () => widget.onAction('play'),
        trailing: widget.selectionMode
            ? null
            : widget.app.mediaLibrary.busy(item.taskId)
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : SiteLensGlassMenuButton<String>(
                tooltip: '媒体文件操作',
                icon: Icons.more_horiz,
                actions: mediaBrowserFileMenuActions(
                  canRename: !widget.showReauthorize,
                  canCopy: !widget.showReauthorize,
                  canDelete: !widget.showReauthorize,
                  enabled: !widget.showReauthorize,
                  moveLabel: '移动到目录',
                  copyLabel: '复制到目录',
                  extraActions: [
                    const SiteLensGlassMenuAction(
                      value: 'details',
                      label: '查看详情',
                      icon: Icons.info_outline,
                    ),
                    const SiteLensGlassMenuAction(
                      value: 'play',
                      label: '原生播放',
                      icon: Icons.play_circle_outline,
                    ),
                    if (widget.app.mediaTasks.task(item.taskId) != null)
                      const SiteLensGlassMenuAction(
                        value: 'cast',
                        label: 'DLNA 投屏',
                        icon: Icons.cast_outlined,
                      ),
                    if (widget.app.mediaTasks.task(item.taskId) != null)
                      SiteLensGlassMenuAction(
                        value: 'regenerate',
                        label: '重新导出 MP4',
                        icon: Icons.file_download_outlined,
                        enabled: !widget.showReauthorize,
                      ),
                    if (widget.showMigration)
                      const SiteLensGlassMenuAction(
                        value: 'migrate',
                        label: '迁移到已配置媒体目录',
                        icon: Icons.drive_file_move_outlined,
                      ),
                    if (widget.showReauthorize)
                      const SiteLensGlassMenuAction(
                        value: 'reauthorize',
                        label: '重新授权媒体目录',
                        icon: Icons.lock_reset_outlined,
                      ),
                  ],
                ),
                onSelected: widget.onAction,
              ),
      );
    },
  );
}

Future<void> showMediaTaskDetails(
  BuildContext context,
  AppController app,
  MediaTask task, {
  MediaArtifact? artifact,
}) async {
  final candidate = await app.db.mediaCandidate(task.candidateId);
  File? file;
  String? fileError;
  try {
    if (artifact == null) {
      file = await app.mediaPlaybackFile(task, preferExported: false);
    }
  } catch (error) {
    fileError = friendlyError(error);
  }
  final stat = await file?.stat();
  int? cacheSize;
  try {
    if (artifact == null) cacheSize = await app.mediaTasks.cachedBytes(task.id);
  } catch (error) {
    fileError ??= friendlyError(error);
  }
  var current = artifact;
  String? metadataError;
  if (current != null) {
    try {
      current = await app.mediaLibrary.inspect(task.id);
    } catch (error) {
      metadataError = friendlyError(error);
    }
  }
  if (!context.mounted) return;
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
            _MediaDetailRow(label: '标题', value: task.displayName),
            if (current != null) ...[
              _MediaDetailRow(label: '文件名', value: current.name),
              _MediaDetailRow(label: '格式', value: current.mime),
              _MediaDetailRow(label: '文件大小', value: formatBytes(current.size)),
              _MediaDetailRow(
                label: '时长',
                value: formatMediaDuration(current.durationMs ?? 0),
              ),
              if ((current.width ?? 0) > 0 && (current.height ?? 0) > 0)
                _MediaDetailRow(
                  label: '分辨率',
                  value: '${current.width} × ${current.height}',
                ),
              _MediaDetailRow(
                label: '保存位置',
                value: readableMediaLocation(current.location),
              ),
            ] else ...[
              _MediaDetailRow(
                label: '状态',
                value: _mediaTaskStateLabel(task.state),
              ),
              _MediaDetailRow(
                label: '缓存大小',
                value: formatBytes(
                  cacheSize ?? stat?.size ?? task.bytesDownloaded,
                ),
              ),
              if (candidate != null)
                _MediaDetailRow(label: '来源格式', value: candidate.effectiveMime),
              if (task.localRef != null)
                _MediaDetailRow(
                  label: '本地缓存',
                  value: readableMediaLocation(task.localRef!),
                ),
            ],
            if (fileError != null)
              _MediaDetailRow(label: '文件检查', value: fileError),
            if (metadataError != null)
              _MediaDetailRow(label: '元数据检查', value: metadataError),
            if (_taskErrorLabel(task).isNotEmpty)
              _MediaDetailRow(label: '错误原因', value: _taskErrorLabel(task)),
            _MediaDetailRow(
              label: '文件夹',
              value: readableMediaLocation(
                mediaFolderDisplayName(task.storageDirectoryName),
              ),
            ),
            _MediaDetailRow(label: '来源页面', value: task.sourceUrl.toString()),
          ],
        ),
      ),
    ),
  );
}

Future<void> castMediaTask(
  BuildContext context,
  AppController app,
  MediaTask task,
) => showDlnaCastControls(context, app, task: task);

class MediaManagementScreen extends StatefulWidget {
  const MediaManagementScreen({super.key, required this.app});

  final AppController app;

  @override
  State<MediaManagementScreen> createState() => _MediaManagementScreenState();
}

class _MediaManagementScreenState extends State<MediaManagementScreen> {
  AppController get app => widget.app;
  String? _expandedDetail;
  late final MediaOrganizationService _libraryOrganization =
      MediaOrganizationService(db: app.db, collection: 'library');
  bool _hasLegacyOrganization = false;
  bool _hasPendingMigration = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLegacyOrganization());
  }

  @override
  void dispose() {
    _libraryOrganization.dispose();
    super.dispose();
  }

  Future<void> _loadLegacyOrganization() async {
    await _libraryOrganization.restore();
    await app.mediaLibrary.restore();
    if (await app.db.setting('mediaLibraryOrganizationMigratedV2') != '1') {
      await _libraryOrganization.restoreAndSync(
        app.mediaLibrary.items.map(
          (item) => MediaOrganizationSeed(
            itemId: item.taskId,
            legacyFolder: app.mediaLibrary.folderFor(item),
          ),
        ),
      );
    }
    var pending = 0;
    try {
      await app.mediaStorage.reconcileMigrationJournal();
      pending = await app.mediaStorage.pendingMigrationCount();
    } catch (_) {
      // Storage migration is optional for rendering this settings page.
    }
    if (mounted) {
      setState(() {
        _hasLegacyOrganization = _libraryOrganization.hasStoredOrganization;
      });
    }
    if (mounted && pending > 0) {
      setState(() => _hasPendingMigration = true);
    }
  }

  Future<void> _pickMp4Directory() async {
    final selected = Platform.isAndroid && app.nativeExports != null
        ? await app.nativeExports!.pickDirectory()
        : await FilePicker.getDirectoryPath(dialogTitle: '选择媒体库目录');
    if (selected == null || selected.trim().isEmpty) return;
    await app.setMp4ExportDirectory(selected);
    await app.mediaStorage.resolve();
    if (mounted) showShortToast(context, '媒体库目录已更新');
  }

  Future<void> _migrateLibrary() async {
    await app.mediaLibrary.restore();
    final root = await app.mediaStorage.resolve();
    if (!root.available) throw StateError('请先选择并授权媒体库目录');
    await _libraryOrganization.restore();
    final folderLocations = <String, String>{};

    Future<String> ensureDirectory(String parent, String name) async {
      final existing = await app.mediaStorage.listDirectory(directory: parent);
      final match = existing
          .where((entry) => entry.directory && entry.name == name)
          .firstOrNull;
      if (match != null) return match.location;
      return app.mediaStorage.createDirectory(parent: parent, name: name);
    }

    Future<void> createFolderTree(
      MediaOrganizationFolder folder,
      String parent,
    ) async {
      final location = await ensureDirectory(parent, folder.name);
      folderLocations[folder.id] = location;
      for (final child in _libraryOrganization.children(folder.id)) {
        await createFolderTree(child, location);
      }
    }

    for (final folder in _libraryOrganization.children(null)) {
      await createFolderTree(folder, root.location);
    }
    var migrated = 0;
    for (final item in [...app.mediaLibrary.items]) {
      final folderId = _libraryOrganization.folderFor(item.taskId);
      final destination = folderId == null
          ? root.location
          : folderLocations[folderId];
      if (destination != null &&
          !await app.mediaStorage.isArtifactInDirectory(item, destination)) {
        await app.mediaStorage.recordMigration(
          taskId: item.taskId,
          source: item.location,
          target: destination,
          fileName: item.name,
          phase: 'planned',
        );
        await app.mediaStorage.moveArtifact(item.taskId, destination);
        await app.mediaStorage.recordMigration(
          taskId: item.taskId,
          source: item.location,
          target: destination,
          fileName: item.name,
          phase: 'moved',
        );
        migrated++;
      }
      final name = _libraryOrganization.nameFor(item.taskId, item.name);
      if (name != item.name) {
        await app.mediaLibrary.rename(item.taskId, name);
      }
      await app.mediaStorage.clearMigration(item.taskId);
    }
    if (_libraryOrganization.hasStoredOrganization) {
      await _libraryOrganization.clearAll();
      await app.db.setSetting('mediaLibraryOrganizationMigratedV2', '1');
      if (mounted) setState(() => _hasLegacyOrganization = false);
    }
    if (mounted) setState(() => _hasPendingMigration = false);
    if (mounted) {
      await app.mediaStorage.resolve();
      if (mounted) {
        showShortToast(
          context,
          migrated == 0 ? '媒体库已是最新位置' : '已迁移 $migrated 个媒体文件',
        );
      }
    }
  }

  String _directoryLabel() {
    final value = app.mp4ExportDirectory?.trim();
    if (value == null || value.isEmpty) return '未配置，使用应用私有媒体库';
    return readableMediaLocation(value);
  }

  Future<void> _resumeWatchSave(WatchSave save) async {
    await app.openUrl(
      save.pageUrl,
      label: save.title,
      profileId: save.profileId,
    );
    if (mounted) {
      showShortToast(context, '已打开观看页面，可继续播放第 ${save.episodeNumber} 集');
    }
  }

  Future<void> _deleteWatchSave(WatchSave save) async {
    await app.watchSaves.delete(save.ownerId);
    if (mounted) showShortToast(context, '已删除观看保存');
  }

  Widget _watchSaveSection() => ListenableBuilder(
    listenable: app.watchSaves,
    builder: (context, _) {
      final saves = [...app.watchSaves.saves]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return SiteLensPanel(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            SiteLensActionRow(
              icon: Icons.bookmark_outline,
              title: '观看保存',
              subtitle: saves.isEmpty
                  ? app.autoSaveWebPlayback
                        ? (app.watchSaves.lastFailureReason == null
                              ? '已开启，等待有效播放记录'
                              : '已开启：${app.watchSaves.lastFailureReason}')
                        : '暂无记录，自动保存已关闭'
                  : '${saves.length} 条观看记录',
            ),
            const SiteLensPanelDivider(),
            SiteLensCompactRow(
              title: const Text('自动保存网页观看记录'),
              subtitle: Text(
                app.autoSaveWebPlayback
                    ? '已开启，稳定识别后保存播放进度'
                    : '已关闭，点击开启；不会创建下载任务',
              ),
              onTap: () => safely(
                context,
                () => app.setAutoSaveWebPlayback(!app.autoSaveWebPlayback),
              ),
              trailing: SiteLensCompactSwitch(
                value: app.autoSaveWebPlayback,
                semanticLabel: '自动保存网页观看记录',
                onChanged: (value) =>
                    safely(context, () => app.setAutoSaveWebPlayback(value)),
              ),
            ),
            if (saves.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('只有确认剧名、集数和实际播放状态后，记录才会出现在这里。'),
                ),
              )
            else
              for (final save in saves) ...[
                const SiteLensPanelDivider(),
                SiteLensCompactRow(
                  key: ValueKey('watch-save-${save.ownerId}'),
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(
                    save.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '第 ${save.episodeNumber} 集 · ${_watchSaveProgressLabel(save)} · ${_watchSaveStateLabel(save.state)} · ${_watchSaveTime(save.updatedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => safely(context, () => _resumeWatchSave(save)),
                  trailing: PopupMenuButton<String>(
                    tooltip: '观看记录操作',
                    onSelected: (value) {
                      if (value == 'delete') {
                        safely(context, () => _deleteWatchSave(save));
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除观看记录')),
                    ],
                  ),
                ),
              ],
          ],
        ),
      );
    },
  );

  Widget _detailText(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(
      SiteLensMetrics.accordionContentIndent,
      0,
      SiteLensMetrics.compactRowHorizontalPadding,
      SiteLensMetrics.compactRowVerticalPadding + 8,
    ),
    child: SelectableText(
      text,
      style: Theme.of(context).textTheme.bodySmall,
      textAlign: TextAlign.start,
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => SiteLensPageScaffold(
      title: '媒体管理',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          SiteLensMetrics.pagePadding,
          12,
          SiteLensMetrics.pagePadding,
          32,
        ),
        children: [
          _watchSaveSection(),
          const SizedBox(height: SiteLensMetrics.sectionGap),
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
                const SiteLensPanelDivider(),
                SiteLensActionRow(
                  icon: Icons.swipe_vertical_outlined,
                  title: '播放器手势',
                  subtitle: app.playerVerticalGesture.label,
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PlayerGesturesScreen(app: app),
                    ),
                  ),
                ),
                const SiteLensPanelDivider(),
                SiteLensCompactRow(
                  title: const Text('下载完成自动导出 MP4'),
                  subtitle: const Text('保留原生HLS，MP4另存一份到媒体库'),
                  onTap: () => safely(
                    context,
                    () => app.setAutoConvertToMp4(!app.autoConvertToMp4),
                  ),
                  trailing: SiteLensCompactSwitch(
                    value: app.autoConvertToMp4,
                    semanticLabel: '下载完成自动导出 MP4',
                    onChanged: (value) =>
                        safely(context, () => app.setAutoConvertToMp4(value)),
                  ),
                ),
                const SiteLensPanelDivider(),
                SiteLensCompactRow(
                  title: const Text('允许边下边播'),
                  subtitle: const Text('仅对已有可用 HLS 分片的下载任务生效'),
                  onTap: () => safely(
                    context,
                    () => app.setAllowStreamingWhileDownloading(
                      !app.allowStreamingWhileDownloading,
                    ),
                  ),
                  trailing: SiteLensCompactSwitch(
                    value: app.allowStreamingWhileDownloading,
                    semanticLabel: '允许边下边播',
                    onChanged: (value) => safely(
                      context,
                      () => app.setAllowStreamingWhileDownloading(value),
                    ),
                  ),
                ),
                const SiteLensPanelDivider(),
                SiteLensDisclosure(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('媒体库目录'),
                  subtitle: Text(
                    app.mp4ExportDirectory == null
                        ? '未配置，使用应用私有媒体库'
                        : '点击查看完整保存路径',
                  ),
                  expanded: _expandedDetail == 'mp4Directory',
                  onToggle: () => setState(() {
                    _expandedDetail = _expandedDetail == 'mp4Directory'
                        ? null
                        : 'mp4Directory';
                  }),
                  details: (context) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _detailText(_directoryLabel()),
                      Padding(
                        padding: const EdgeInsets.only(
                          left: SiteLensMetrics.accordionContentIndent,
                          bottom: SiteLensMetrics.compactRowVerticalPadding + 8,
                        ),
                        child: TextButton.icon(
                          onPressed: () => safely(context, _pickMp4Directory),
                          icon: const Icon(Icons.folder_open_outlined),
                          label: Text(
                            app.mp4ExportDirectory == null
                                ? '选择媒体目录'
                                : '更换媒体目录',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (app.mp4ExportDirectory != null ||
                    _hasLegacyOrganization ||
                    _hasPendingMigration) ...[
                  const SiteLensPanelDivider(),
                  SiteLensDisclosure(
                    leading: const Icon(Icons.library_music_outlined),
                    title: const Text('迁移应用媒体库'),
                    subtitle: const Text('将应用私有文件迁移到当前媒体目录'),
                    expanded: _expandedDetail == 'mediaLibrary',
                    onToggle: () => setState(() {
                      _expandedDetail = _expandedDetail == 'mediaLibrary'
                          ? null
                          : 'mediaLibrary';
                    }),
                    details: (context) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _detailText('迁移会保留媒体身份并校验文件内容；权限失效或同名冲突时不会删除源文件。'),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: SiteLensMetrics.accordionContentIndent,
                            bottom: SiteLensMetrics.compactRowVerticalPadding,
                          ),
                          child: TextButton(
                            onPressed: () => safely(context, _migrateLibrary),
                            child: const Text('开始迁移'),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: SiteLensMetrics.accordionContentIndent,
                            bottom:
                                SiteLensMetrics.compactRowVerticalPadding + 8,
                          ),
                          child: TextButton(
                            onPressed: () => safely(
                              context,
                              () => app.setMp4ExportDirectory(null),
                            ),
                            child: const Text('清除媒体目录配置'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String _watchSaveStateLabel(WatchSaveState state) => switch (state) {
  WatchSaveState.playing => '播放中',
  WatchSaveState.paused => '已暂停',
  WatchSaveState.ended => '已结束',
  WatchSaveState.unknown => '状态未知',
};

String _watchSaveProgressLabel(WatchSave save) {
  final duration = save.durationMs;
  if (duration == null || duration <= 0) {
    return formatMediaDuration(save.positionMs);
  }
  return '${formatMediaDuration(save.positionMs)} / ${formatMediaDuration(duration)}';
}

String _watchSaveTime(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$month-$day $hour:$minute';
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
  bool _batchBusy = false;
  late final MediaOrganizationService _organization = MediaOrganizationService(
    db: widget.app.db,
    collection: 'tasks',
  );
  late final MediaBrowserController _browser = MediaBrowserController(
    organization: _organization,
  );

  @override
  void initState() {
    super.initState();
    widget.app.mediaTasks.addListener(_tasksChanged);
    _organization.addListener(_tasksChanged);
    _browser.addListener(_tasksChanged);
    unawaited(_syncOrganization());
    _mediaStates = widget.app.nativeMedia.states.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_refreshCachedFiles());
    if (widget.app.nativeDownloads != null) {
      _poller = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_pollNativeTasks());
      });
    }
  }

  @override
  void dispose() {
    widget.app.mediaTasks.removeListener(_tasksChanged);
    _organization.removeListener(_tasksChanged);
    _browser.removeListener(_tasksChanged);
    _browser.dispose();
    _poller?.cancel();
    _mediaStates?.cancel();
    super.dispose();
  }

  void _tasksChanged() {
    if (mounted) setState(() {});
    unawaited(_syncOrganization());
  }

  String? _startupError;
  Future<void> _syncOrganization() async {
    try {
      await widget.app.mediaTasks.ready;
      if (!mounted) return;
      await _organization.restoreAndSync(
        widget.app.mediaTasks.tasks.map(
          (task) => MediaOrganizationSeed(
            itemId: task.id,
            legacyFolder: task.batchDirectory,
          ),
        ),
      );
      if (mounted && _startupError != null) {
        setState(() => _startupError = null);
      }
    } catch (error) {
      if (mounted) setState(() => _startupError = friendlyError(error));
    }
  }

  MediaBrowserOperations get _browserOperations => MediaBrowserOperations(
    renameItem: (id, name) => _organization.renameItem(id, name),
    moveItem: (id, folderId) => _organization.moveItems([id], folderId),
    copyItem: (id) async => (await widget.app.mediaTasks.copyCompleted(id)).id,
    deleteItem: widget.app.deleteMediaTask,
    preflightDelete: (id) async =>
        widget.app.mediaTasks.canDelete(id) ? null : '媒体正在播放、导出或投屏，请先停止',
    preflightCopy: (id) async {
      final task = widget.app.mediaTasks.task(id);
      if (task == null) return '媒体任务不存在';
      if (!widget.app.mediaTasks.canDelete(id)) {
        return '媒体正在播放、导出或投屏，请先停止';
      }
      if (!_isBatchExportable(task) ||
          task.totalBytes != null && task.bytesDownloaded < task.totalBytes!) {
        return '任务尚未完整下载，无法复制';
      }
      return null;
    },
  );

  Future<void> _createTaskFolder() async {
    final name = await showMediaBrowserNameDialog(
      context,
      title: '新建文件夹',
      initial: '',
      label: '文件夹名称',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await safely(
      context,
      () => _organization.createFolder(name, parentId: _browser.folderId),
    );
  }

  Future<void> _taskFolderAction(
    MediaOrganizationFolder folder,
    String action,
  ) async {
    switch (action) {
      case 'rename':
        final name = await showMediaBrowserNameDialog(
          context,
          title: '重命名文件夹',
          initial: folder.name,
          label: '文件夹名称',
        );
        if (name != null && name.trim().isNotEmpty) {
          await _organization.renameFolder(folder.id, name);
        }
      case 'move':
        final choice = await showMediaBrowserFolderPicker(
          context,
          _organization,
          excludedFolderIds: {
            folder.id,
            ..._organization.descendantsOf(folder.id),
          },
        );
        if (choice.confirmed) {
          await _organization.moveFolder(folder.id, choice.folderId);
        }
      case 'copy':
        final result = await runMediaBrowserFolderCopy(
          context,
          organization: _organization,
          operations: _browserOperations,
          folderId: folder.id,
        );
        if (mounted && result.failed.isNotEmpty) {
          showShortToast(
            context,
            '已复制 ${result.succeeded.length} 项，${result.failed.length} 项失败',
          );
        }
      case 'delete':
        final result = await runMediaBrowserDelete(
          context,
          organization: _organization,
          operations: _browserOperations,
          itemIds: _organization.itemIdsInFolder(folder.id),
          title: '删除文件夹内容',
          message: '删除“${folder.name}”中的媒体任务？已导出的 MP4 保留。',
        );
        if (mounted && result.failed.isNotEmpty) {
          showShortToast(
            context,
            '已删除 ${result.succeeded.length} 项，${result.failed.length} 项失败',
          );
        }
      case 'retry':
        await _runFolderBatch(folder.id, _MediaBatchAction.retry);
      case 'refresh':
        await _runFolderBatch(folder.id, _MediaBatchAction.refresh);
      case 'export':
        await _runFolderBatch(folder.id, _MediaBatchAction.export);
    }
  }

  Future<void> _taskFileManagement(String action, MediaTask task) async {
    switch (action) {
      case 'rename':
        final name = await showMediaBrowserNameDialog(
          context,
          title: '重命名媒体任务',
          initial: _organization.nameFor(task.id, task.displayName),
          label: '显示名称',
        );
        if (name != null && name.trim().isNotEmpty) {
          await _organization.renameItem(task.id, name);
        }
      case 'move':
        final choice = await showMediaBrowserFolderPicker(
          context,
          _organization,
        );
        if (choice.confirmed) {
          await _organization.moveItems([task.id], choice.folderId);
        }
      case 'copy':
        final choice = await showMediaBrowserFolderPicker(
          context,
          _organization,
        );
        if (choice.confirmed) {
          final copied = await widget.app.mediaTasks.copyCompleted(task.id);
          await _organization.clonePlacement(
            task.id,
            copied.id,
            folderId: choice.folderId,
          );
        }
      case 'delete':
        final result = await runMediaBrowserDelete(
          context,
          organization: _organization,
          operations: _browserOperations,
          itemIds: [task.id],
          title: '删除媒体任务',
          message: '删除“${task.displayName}”的任务和下载缓存？已导出的 MP4 保留。',
        );
        if (mounted && result.failed.isNotEmpty) {
          showShortToast(context, '删除失败：${result.failed.values.first}');
        }
    }
  }

  Future<void> _taskSharedBatchAction(String action) async {
    if (_browser.busy) return;
    _browser.busy = true;
    _browser.refresh();
    final itemIds = _browser.selectedItemIds.toList();
    final folderIds = _browser.selectedFolderIds.toList();
    try {
      switch (action) {
        case 'move':
          await runMediaBrowserMove(
            context: context,
            organization: _organization,
            itemIds: itemIds,
            folderIds: folderIds,
            currentFolderId: _browser.folderId,
          );
        case 'copy':
          final choice = await showMediaBrowserFolderPicker(
            context,
            _organization,
          );
          if (!mounted || !choice.confirmed) return;
          final result = await runMediaBrowserCopySelection(
            context,
            organization: _organization,
            operations: _browserOperations,
            itemIds: itemIds,
            folderIds: folderIds,
            destination: choice.folderId,
          );
          if (mounted && result.failed.isNotEmpty) {
            showShortToast(
              context,
              '已复制 ${result.succeeded.length} 项，${result.failed.length} 项失败',
            );
          }
        case 'delete':
          final result = await runMediaBrowserDeleteSelection(
            context,
            organization: _organization,
            operations: _browserOperations,
            itemIds: itemIds,
            folderIds: folderIds,
            title: '删除选中的媒体任务',
            message: '删除选中的 ${itemIds.length} 个任务和下载缓存？已导出的 MP4 保留。',
          );
          if (mounted && result.failed.isNotEmpty) {
            showShortToast(
              context,
              '已删除 ${result.succeeded.length} 项，${result.failed.length} 项失败',
            );
          }
      }
    } finally {
      _browser.busy = false;
      _browser.refresh();
      if (mounted) _browser.exitSelection();
    }
  }

  Future<void> _refreshCachedFiles() async {
    try {
      await widget.app.mediaTasks.reconcileCachedFiles();
      widget.app.notifyMediaChanged();
      if (mounted) setState(() {});
    } catch (error, stack) {
      AppErrorLogger.capture(error, module: 'media.cache', stack: stack);
    }
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
    if (mounted) setState(() {});
    await safely(context, action);
    _operations.remove(key);
    if (mounted) setState(() {});
  }

  bool _taskBusy(String taskId) => _operations.contains(taskId);

  Future<void> _refreshNative(MediaTask task) async {
    await widget.app.mediaDownloads.refreshTask(task.id);
    if (mounted) setState(() {});
  }

  Future<void> _play(MediaTask task) async {
    await openMediaTaskPlayer(context, widget.app, task);
  }

  Future<void> _togglePause(MediaTask task) async {
    if (task.state == MediaTaskState.downloading) {
      await widget.app.mediaDownloads.pause(task.id);
    } else if (task.state == MediaTaskState.paused) {
      final candidate = await widget.app.mediaCandidateForRetry(task);
      await widget.app.mediaDownloads.resumeNative(task.id, candidate);
    }
    if (mounted) setState(() {});
  }

  Future<void> _retry(MediaTask task, {bool notify = true}) async {
    final resolved = await widget.app.mediaCandidateForRetry(task);
    final currentTask = widget.app.mediaTasks.task(task.id) ?? task;
    if (task.state == MediaTaskState.paused) {
      await _togglePause(task);
    } else if (task.state == MediaTaskState.reauthorize) {
      final refresh = await widget.app.refreshMediaAuthorization(
        task,
        resolved,
      );
      if (!refresh.refreshed) {
        throw StateError(
          refresh.reason ??
              (refresh.waitingExecution ? '等待系统允许后台授权刷新' : '需要人工重新授权'),
        );
      }
      final rebound = await widget.app.mediaCandidateForRetry(task);
      await widget.app.mediaDownloads.resumeNative(task.id, rebound);
    } else if (task.errorCode == MediaErrorCode.cacheMissing) {
      await widget.app.mediaDownloads.delete(task.id, deleteTask: false);
      await widget.app.mediaDownloads.startNative(
        widget.app.mediaTasks.task(task.id)!,
        resolved,
      );
    } else if (task.state == MediaTaskState.failed &&
        widget.app.nativeDownloads != null &&
        !resolved.isHls) {
      await widget.app.mediaDownloads.resumeNative(task.id, resolved);
    } else {
      await widget.app.mediaDownloads.startNative(currentTask, resolved);
    }
    if (mounted && notify) {
      showShortToast(context, '已开始续传');
      setState(() {});
    }
  }

  Future<void> _showDetails(MediaTask task, MediaCandidate? candidate) =>
      showMediaTaskDetails(context, widget.app, task);

  Future<void> _cast(MediaTask task) =>
      castMediaTask(context, widget.app, task);

  Future<void> _export(MediaTask task) async {
    showShortToast(context, '正在导出 MP4');
    await widget.app.exportMediaTask(task);
    if (mounted) {
      showShortToast(
        context,
        widget.app.mp4ExportDirectory == null ? 'MP4 已保存在媒体库' : 'MP4 已保存到配置目录',
      );
    }
  }

  bool _isBatchExportable(MediaTask task) =>
      task.state == MediaTaskState.completed ||
      task.state == MediaTaskState.playable;

  bool _isBatchSelectable(MediaTask task) => !_batchBusy && !_taskBusy(task.id);

  bool _batchEligible(MediaTask task, _MediaBatchAction action) =>
      switch (action) {
        _MediaBatchAction.export => _isBatchExportable(task),
        _MediaBatchAction.retry => {
          MediaTaskState.failed,
          MediaTaskState.cancelled,
          MediaTaskState.paused,
          MediaTaskState.reauthorize,
        }.contains(task.state),
        _MediaBatchAction.refresh || _MediaBatchAction.delete => true,
      };

  Future<void> _runFolderBatch(
    String folderId,
    _MediaBatchAction action,
  ) async {
    await _runBatch(
      action,
      taskIds: _organization.itemIdsInFolder(folderId),
      retainFailedSelection: false,
    );
  }

  Future<void> _runBatch(
    _MediaBatchAction action, {
    Iterable<String>? taskIds,
    bool retainFailedSelection = true,
  }) async {
    if (_batchBusy || !mounted) return;
    final selectedIds = taskIds == null
        ? <String>{..._browser.selectedItemIds}
        : taskIds.toSet();
    if (taskIds == null) {
      for (final folderId in _browser.selectedFolderIds) {
        selectedIds.addAll(_organization.itemIdsInFolder(folderId));
      }
    }
    final selected = widget.app.mediaTasks.tasks
        .where((task) => selectedIds.contains(task.id))
        .toList();
    if (selected.isEmpty) return;
    setState(() {
      _batchBusy = true;
      _browser.busy = true;
    });
    final failedIds = <String>{};
    var succeeded = 0;
    var skipped = 0;
    try {
      if (action == _MediaBatchAction.delete) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => SiteLensAlertDialog(
            title: const Text('批量删除媒体任务'),
            content: Text(
              '删除选中的 ${selected.length} 个任务和下载缓存？已导出媒体文件保留，正在使用的任务会保留。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      for (final snapshot in selected) {
        final task = widget.app.mediaTasks.task(snapshot.id);
        if (task == null || !_batchEligible(task, action)) {
          skipped++;
          continue;
        }
        if (!_operations.add(task.id)) {
          failedIds.add(task.id);
          continue;
        }
        try {
          switch (action) {
            case _MediaBatchAction.retry:
              await _retry(task, notify: false);
            case _MediaBatchAction.refresh:
              await _refreshNative(task);
            case _MediaBatchAction.export:
              await widget.app.exportMediaTask(task);
            case _MediaBatchAction.delete:
              await widget.app.deleteMediaTask(task.id);
          }
          succeeded++;
        } catch (error, stack) {
          failedIds.add(task.id);
          AppErrorLogger.capture(
            error,
            stack: stack,
            module: 'media.batch',
            context: '${action.name}:${task.id}',
          );
        } finally {
          _operations.remove(task.id);
        }
      }
      if (!mounted) return;
      if (mounted && retainFailedSelection) {
        _browser.selectedItemIds
          ..clear()
          ..addAll(failedIds);
        _browser.selectionMode = failedIds.isNotEmpty;
        setState(() {});
      }
      final verb = switch (action) {
        _MediaBatchAction.retry => '已重试',
        _MediaBatchAction.refresh => '已刷新',
        _MediaBatchAction.export => '已导出',
        _MediaBatchAction.delete => '已删除',
      };
      showShortToast(
        context,
        [
          '$verb $succeeded 个',
          if (failedIds.isNotEmpty) '${failedIds.length} 个失败',
          if (skipped > 0) '跳过 $skipped 个',
        ].join('，'),
      );
    } finally {
      if (mounted) {
        setState(() {
          _batchBusy = false;
          _browser.busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allTasks = widget.app.mediaTasks.tasks;
    final visibleTasks = allTasks
        .where((task) => _organization.folderFor(task.id) == _browser.folderId)
        .toList();
    final folders = _browser.folders;
    _browser.pruneSelection(
      itemIds: visibleTasks.map((task) => task.id),
      folderIds: folders.map((folder) => folder.id),
    );
    final activePlayback = widget.app.nativeMedia.active;
    final current = _browser.currentFolder;
    final selectionExtras = <SiteLensGlassMenuAction<String>>[
      const SiteLensGlassMenuAction(
        value: 'retry',
        label: '批量重试下载',
        icon: Icons.replay,
      ),
      const SiteLensGlassMenuAction(
        value: 'refresh',
        label: '批量刷新后台状态',
        icon: Icons.refresh,
      ),
      const SiteLensGlassMenuAction(
        value: 'export',
        label: '批量导出 MP4',
        icon: Icons.file_download_outlined,
      ),
    ];
    return SiteLensPageScaffold(
      title: _browser.selectionMode ? '已选 ${_browser.selectedCount} 项' : '媒体任务',
      actions: [
        if (!_browser.selectionMode) ...[
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _createTaskFolder,
          ),
          IconButton(
            tooltip: '选择任务',
            icon: const Icon(Icons.checklist),
            onPressed: _browser.enterSelection,
          ),
        ] else
          MediaBrowserSelectionActions(
            controller: _browser,
            visibleItemIds: visibleTasks.map((task) => task.id),
            visibleFolderIds: folders.map((folder) => folder.id),
            onAction: (action) => unawaited(_taskSharedBatchAction(action)),
            extraActions: selectionExtras,
            onExtraAction: (action) {
              final value = _MediaBatchAction.values.firstWhere(
                (candidate) => candidate.name == action,
              );
              unawaited(_runBatch(value));
            },
          ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SiteLensMetrics.pagePadding,
              12,
              SiteLensMetrics.pagePadding,
              0,
            ),
            child: SiteLensHelpNotice(
              app: widget.app,
              noticeId: 'media.tasks',
              text: '这里管理媒体任务的下载、播放和导出，可批量重试、刷新、删除或导出。',
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                SiteLensMetrics.pagePadding,
                12,
                SiteLensMetrics.pagePadding,
                0,
              ),
              child: SiteLensPanel(
                padding: EdgeInsets.zero,
                child: CustomScrollView(
                  key: const PageStorageKey('media-tasks-scroll'),
                  slivers: [
                    if (_startupError != null)
                      SliverToBoxAdapter(
                        child: SiteLensCompactRow(
                          leading: const Icon(Icons.error_outline),
                          title: const Text('媒体任务恢复失败'),
                          subtitle: Text(_startupError!),
                        ),
                      )
                    else if (!widget.app.mediaTasks.available)
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(),
                      ),
                    if (activePlayback != null)
                      SliverToBoxAdapter(
                        child: _ActiveMediaPlaybackRow(
                          app: widget.app,
                          session: activePlayback,
                          run: _run,
                        ),
                      ),
                    if (activePlayback != null)
                      const SliverToBoxAdapter(child: SiteLensPanelDivider()),
                    if (current != null)
                      SliverToBoxAdapter(
                        child: MediaBrowserFolderRow(
                          folder: current,
                          itemCount: visibleTasks.length,
                          parent: true,
                          taskGroup: true,
                          onOpen: _browser.goUp,
                          onAction: (_) {},
                        ),
                      ),
                    if (folders.isNotEmpty)
                      SliverList.builder(
                        itemCount: folders.length * 2 - 1,
                        itemBuilder: (_, index) {
                          if (index.isOdd) return const SiteLensPanelDivider();
                          final folder = folders[index ~/ 2];
                          return MediaBrowserFolderRow(
                            folder: folder,
                            itemCount: _organization
                                .itemIdsInFolder(folder.id)
                                .length,
                            taskGroup: true,
                            selectionMode: _browser.selectionMode,
                            selected: _browser.selectedFolderIds.contains(
                              folder.id,
                            ),
                            onSelected: (_) => _browser.toggleFolder(folder.id),
                            onOpen: () => _browser.openFolder(folder.id),
                            onAction: (action) => safely(
                              context,
                              () => _taskFolderAction(folder, action),
                            ),
                            extraActions: const [
                              SiteLensGlassMenuAction(
                                value: 'retry',
                                label: '重试文件夹任务',
                                icon: Icons.replay,
                              ),
                              SiteLensGlassMenuAction(
                                value: 'refresh',
                                label: '刷新文件夹状态',
                                icon: Icons.refresh,
                              ),
                              SiteLensGlassMenuAction(
                                value: 'export',
                                label: '导出文件夹 MP4',
                                icon: Icons.file_download_outlined,
                              ),
                            ],
                          );
                        },
                      ),
                    if (widget.app.mediaTasks.available &&
                        _startupError == null &&
                        visibleTasks.isEmpty &&
                        (current != null ||
                            (folders.isEmpty && allTasks.isEmpty)))
                      SliverToBoxAdapter(
                        child: SiteLensCompactRow(
                          leading: Icon(
                            current == null
                                ? Icons.download_done
                                : Icons.folder_open_outlined,
                            size: 18,
                          ),
                          title: Text(current == null ? '暂无媒体任务' : '文件夹为空'),
                          subtitle: Text(
                            current == null
                                ? '在浏览器的「媒体候选」中选择地址开始缓存。'
                                : '可以移动或复制媒体任务到这里。',
                          ),
                        ),
                      ),
                    if (visibleTasks.isNotEmpty)
                      SliverList.builder(
                        itemCount: visibleTasks.length,
                        itemBuilder: (context, index) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildMediaTaskRow(context, visibleTasks[index]),
                            if (index < visibleTasks.length - 1)
                              const SiteLensPanelDivider(),
                          ],
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaTaskRow(BuildContext context, MediaTask task) =>
      _MediaTaskRow(
        key: ValueKey(task.id),
        app: widget.app,
        task: task,
        organization: _organization,
        browser: _browser,
        busy: _taskBusy(task.id),
        isBatchSelectable: _isBatchSelectable,
        isBatchExportable: _isBatchExportable,
        taskTitle: _taskTitle,
        taskProgress: _taskProgress,
        taskProgressLabel: _taskProgressLabel,
        taskErrorLabel: _taskErrorLabel,
        onRefresh: (value) =>
            _run(() => _refreshNative(value), taskId: value.id),
        onDetails: _showDetails,
        onPlay: (value) => _run(() => _play(value), taskId: value.id),
        onCast: (value) => _run(() => _cast(value), taskId: value.id),
        onExport: (value) => _run(() => _export(value), taskId: value.id),
        onCancel: (value) => _run(() async {
          await widget.app.mediaDownloads.cancel(value.id);
          if (mounted) setState(() {});
        }, taskId: value.id),
        onPause: (value) => _run(() => _togglePause(value), taskId: value.id),
        onRetry: (value) => _run(() => _retry(value), taskId: value.id),
        onFileManagement: (action, value) =>
            _run(() => _taskFileManagement(action, value), taskId: value.id),
      );

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
    final frozen = mediaPlaylistEntryName(
      widget.app.mediaTasks.tasks,
      task,
    ).trim();
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

class _MediaTaskRow extends StatefulWidget {
  const _MediaTaskRow({
    super.key,
    required this.app,
    required this.task,
    required this.organization,
    required this.browser,
    required this.busy,
    required this.isBatchSelectable,
    required this.isBatchExportable,
    required this.taskTitle,
    required this.taskProgress,
    required this.taskProgressLabel,
    required this.taskErrorLabel,
    required this.onRefresh,
    required this.onDetails,
    required this.onPlay,
    required this.onCast,
    required this.onExport,
    required this.onCancel,
    required this.onPause,
    required this.onRetry,
    required this.onFileManagement,
  });

  final AppController app;
  final MediaTask task;
  final MediaOrganizationService organization;
  final MediaBrowserController browser;
  final bool busy;
  final bool Function(MediaTask) isBatchSelectable;
  final bool Function(MediaTask) isBatchExportable;
  final String Function(MediaTask, MediaCandidate?) taskTitle;
  final double? Function(MediaTask) taskProgress;
  final String Function(MediaTask) taskProgressLabel;
  final String Function(MediaTask) taskErrorLabel;
  final Future<void> Function(MediaTask) onRefresh;
  final Future<void> Function(MediaTask, MediaCandidate?) onDetails;
  final Future<void> Function(MediaTask) onPlay;
  final Future<void> Function(MediaTask) onCast;
  final Future<void> Function(MediaTask) onExport;
  final Future<void> Function(MediaTask) onCancel;
  final Future<void> Function(MediaTask) onPause;
  final Future<void> Function(MediaTask) onRetry;
  final Future<void> Function(String, MediaTask) onFileManagement;

  @override
  State<_MediaTaskRow> createState() => _MediaTaskRowState();
}

class _MediaTaskRowState extends State<_MediaTaskRow> {
  late Future<MediaCandidate?> _candidate;
  late Future<MediaArtifact?> _artifact;

  @override
  void initState() {
    super.initState();
    _resetSources();
  }

  @override
  void didUpdateWidget(covariant _MediaTaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldArtifact = oldWidget.app.mediaLibrary.item(oldWidget.task.id);
    final newArtifact = widget.app.mediaLibrary.item(widget.task.id);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.task.candidateId != widget.task.candidateId ||
        oldArtifact?.location != newArtifact?.location ||
        oldArtifact?.thumbnailPath != newArtifact?.thumbnailPath) {
      _resetSources();
    }
  }

  void _resetSources() {
    _candidate = widget.app.db.mediaCandidate(widget.task.candidateId);
    _artifact = _resolveArtifact();
  }

  Future<MediaArtifact?> _resolveArtifact() async {
    final current = widget.app.mediaLibrary.item(widget.task.id);
    if (current == null) return null;
    final thumbnail = current.thumbnailPath;
    if (thumbnail != null && !thumbnail.startsWith('content:')) {
      try {
        if (await File(thumbnail).exists()) return current;
      } catch (_) {
        // Let the catalog inspection try to recover the local frame.
      }
    }
    try {
      return await widget.app.mediaLibrary.inspect(widget.task.id);
    } catch (_) {
      return current;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MediaCandidate?>(
    future: _candidate,
    builder: (context, candidateSnapshot) => FutureBuilder<MediaArtifact?>(
      future: _artifact,
      builder: (context, artifactSnapshot) {
        final candidate = candidateSnapshot.data;
        final artifact =
            artifactSnapshot.data ??
            widget.app.mediaLibrary.item(widget.task.id);
        final busy = widget.busy;
        final menu = SiteLensGlassMenuButton<String>(
          tooltip: '媒体任务操作',
          icon: Icons.more_horiz,
          actions: mediaBrowserFileMenuActions(
            enabled: !busy,
            renameLabel: '重命名任务',
            moveLabel: '移动到任务分组',
            copyLabel: '复制任务',
            extraActions: [
              SiteLensGlassMenuAction(
                value: 'refresh',
                label: '刷新后台状态',
                icon: Icons.refresh,
                enabled: !busy,
              ),
              const SiteLensGlassMenuAction(
                value: 'details',
                label: '查看详情',
                icon: Icons.info_outline,
              ),
              if (widget.task.state == MediaTaskState.playable)
                SiteLensGlassMenuAction(
                  value: 'play',
                  label: '原生播放',
                  icon: Icons.play_circle_outline,
                  enabled: !busy,
                ),
              if (widget.app.allowStreamingWhileDownloading &&
                  candidate?.isHls == true &&
                  (widget.task.state == MediaTaskState.downloading ||
                      widget.task.state == MediaTaskState.paused))
                SiteLensGlassMenuAction(
                  value: 'play',
                  label: '边下边播',
                  icon: Icons.play_arrow,
                  enabled: !busy,
                ),
              if (widget.task.state == MediaTaskState.playable)
                SiteLensGlassMenuAction(
                  value: 'cast',
                  label: 'DLNA 投屏',
                  icon: Icons.cast_outlined,
                  enabled: !busy,
                ),
              if (widget.isBatchExportable(widget.task))
                SiteLensGlassMenuAction(
                  value: 'export',
                  label: '导出 MP4',
                  icon: Icons.file_download_outlined,
                  enabled: !busy,
                ),
              if (widget.task.state == MediaTaskState.downloading)
                SiteLensGlassMenuAction(
                  value: 'pause',
                  label: '暂停下载',
                  icon: Icons.pause_circle_outline,
                  enabled: !busy,
                ),
              if (widget.task.state == MediaTaskState.paused)
                SiteLensGlassMenuAction(
                  value: 'pause',
                  label: '继续下载',
                  icon: Icons.play_circle_outline,
                  enabled: !busy,
                ),
              if (widget.task.state == MediaTaskState.failed ||
                  widget.task.state == MediaTaskState.cancelled ||
                  widget.task.state == MediaTaskState.reauthorize)
                SiteLensGlassMenuAction(
                  value: 'retry',
                  label: widget.task.state == MediaTaskState.reauthorize
                      ? '刷新授权后重试'
                      : '重试下载',
                  icon: Icons.replay,
                  enabled: !busy,
                ),
              if (widget.task.state == MediaTaskState.downloading ||
                  widget.task.state == MediaTaskState.paused)
                SiteLensGlassMenuAction(
                  value: 'cancel',
                  label: '取消下载',
                  icon: Icons.cancel_outlined,
                  enabled: !busy,
                ),
            ],
          ),
          onSelected: (value) {
            switch (value) {
              case 'refresh':
                unawaited(widget.onRefresh(widget.task));
              case 'details':
                unawaited(widget.onDetails(widget.task, candidate));
              case 'play':
                unawaited(widget.onPlay(widget.task));
              case 'cast':
                unawaited(widget.onCast(widget.task));
              case 'export':
                unawaited(widget.onExport(widget.task));
              case 'cancel':
                unawaited(widget.onCancel(widget.task));
              case 'pause':
                unawaited(widget.onPause(widget.task));
              case 'retry':
                unawaited(widget.onRetry(widget.task));
              case 'rename':
              case 'move':
              case 'copy':
              case 'delete':
                unawaited(widget.onFileManagement(value, widget.task));
            }
          },
        );
        final leading = widget.browser.selectionMode
            ? Checkbox(
                value: widget.browser.selectedItemIds.contains(widget.task.id),
                onChanged: widget.isBatchSelectable(widget.task)
                    ? (_) => widget.browser.toggleItem(widget.task.id)
                    : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )
            : _TaskThumbnail(
                task: widget.task,
                candidate: candidate,
                candidateLoading:
                    candidateSnapshot.connectionState ==
                    ConnectionState.waiting,
                localThumbnailPath: artifact?.thumbnailPath,
              );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SiteLensCompactRow(
              leading: leading,
              title: Text(
                widget.organization.nameFor(
                  widget.task.id,
                  widget.taskTitle(widget.task, candidate),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_mediaTaskStateLabel(widget.task.state)} · ${widget.taskProgressLabel(widget.task)}${widget.taskErrorLabel(widget.task).isEmpty ? '' : ' · ${widget.taskErrorLabel(widget.task)}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: widget.browser.selectionMode
                  ? (widget.isBatchSelectable(widget.task)
                        ? () => widget.browser.toggleItem(widget.task.id)
                        : null)
                  : widget.task.state == MediaTaskState.playable ||
                        (widget.app.allowStreamingWhileDownloading &&
                            candidate?.isHls == true &&
                            (widget.task.state == MediaTaskState.downloading ||
                                widget.task.state == MediaTaskState.paused))
                  ? () => unawaited(widget.onPlay(widget.task))
                  : null,
              trailing: widget.browser.selectionMode
                  ? Text(
                      widget.isBatchSelectable(widget.task) ? '可处理' : '执行中',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  : SizedBox(
                      width: kMinInteractiveDimension,
                      height: kMinInteractiveDimension,
                      child: menu,
                    ),
            ),
            if (widget.task.state == MediaTaskState.downloading ||
                widget.task.state == MediaTaskState.paused)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                child: LinearProgressIndicator(
                  value: widget.taskProgress(widget.task),
                  minHeight: 4,
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _ActiveMediaPlaybackRow extends StatelessWidget {
  const _ActiveMediaPlaybackRow({
    required this.app,
    required this.session,
    required this.run,
  });

  final AppController app;
  final NativePlaybackSession session;
  final Future<void> Function(Future<void> Function(), {String? taskId}) run;

  @override
  Widget build(BuildContext context) => SiteLensCompactRow(
    leading: const Icon(Icons.play_circle_filled, size: 18),
    title: Text(
      '原生播放：${_mediaTaskStateLabel(_nativeStateAsTaskState(session.state))}',
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: session.state == NativePlaybackState.playing ? '暂停' : '播放',
          icon: Icon(
            session.state == NativePlaybackState.playing
                ? Icons.pause
                : Icons.play_arrow,
          ),
          onPressed: () => run(() async {
            if (session.state == NativePlaybackState.playing) {
              await app.nativeMedia.pause(sessionId: session.id);
            } else {
              await app.nativeMedia.play(sessionId: session.id);
            }
          }, taskId: session.id),
        ),
        IconButton(
          tooltip: '停止',
          icon: const Icon(Icons.stop),
          onPressed: () => run(
            () => app.nativeMedia.stop(sessionId: session.id),
            taskId: session.id,
          ),
        ),
      ],
    ),
  );
}

MediaTaskState _nativeStateAsTaskState(NativePlaybackState state) =>
    switch (state) {
      NativePlaybackState.preparing => MediaTaskState.downloading,
      NativePlaybackState.playing => MediaTaskState.playable,
      NativePlaybackState.paused => MediaTaskState.paused,
      NativePlaybackState.buffering => MediaTaskState.downloading,
      NativePlaybackState.completed => MediaTaskState.completed,
      NativePlaybackState.restorable => MediaTaskState.paused,
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
  const _TaskThumbnail({
    required this.task,
    this.candidate,
    this.candidateLoading = false,
    this.localThumbnailPath,
  });
  final MediaTask task;
  final MediaCandidate? candidate;
  final bool candidateLoading;
  final String? localThumbnailPath;

  @override
  Widget build(BuildContext context) {
    final thumbnail = candidate?.thumbnailUrl;
    final local = localThumbnailPath;
    final localImage = local == null || local.startsWith('content:')
        ? null
        : FileImage(File(local));
    final networkImage = thumbnail == null
        ? null
        : NetworkImage(thumbnail.toString());
    final ImageProvider? image =
        localImage ?? (candidateLoading ? null : networkImage);
    final ImageProvider? fallback = localImage == null || candidateLoading
        ? null
        : networkImage;
    return MediaThumbnail(
      image: image,
      fallbackImage: fallback,
      placeholder: task.state == MediaTaskState.playable
          ? Icons.play_circle
          : Icons.downloading,
    );
  }
}
