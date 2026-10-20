import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../diagnostics/error_log.dart';
import '../media/dlna_service.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

/// Opens the shared DLNA device picker and control surface.
///
/// Pass an existing [task] for a downloaded local file. Pass an authorized
/// [candidate] for a user-selected remote media URL; the task is created only
/// after the user chooses to cast and is retained by the cast session.
/// Omit both to reopen the currently active session without replacing it.
Future<void> showDlnaCastControls(
  BuildContext context,
  AppController app, {
  MediaTask? task,
  MediaCandidate? candidate,
  Duration? initialPosition,
  Future<void> Function()? onCastStarted,
  DlnaCastController? controller,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => DlnaCastScreen(
      app: app,
      task: task,
      candidate: candidate,
      initialPosition: initialPosition,
      onCastStarted: onCastStarted,
      controller: controller,
    ),
  ),
);

class DlnaCastScreen extends StatefulWidget {
  const DlnaCastScreen({
    super.key,
    required this.app,
    this.task,
    this.candidate,
    this.initialPosition,
    this.onCastStarted,
    this.discovery = const DlnaDiscovery(),
    this.controller,
  });

  final AppController app;
  final MediaTask? task;
  final MediaCandidate? candidate;
  final Duration? initialPosition;
  final Future<void> Function()? onCastStarted;
  final DlnaDiscovery discovery;
  final DlnaCastController? controller;

  @override
  State<DlnaCastScreen> createState() => _DlnaCastScreenState();
}

class _DlnaCastScreenState extends State<DlnaCastScreen> {
  List<CastDevice> _devices = const [];
  bool _searching = false;
  String? _error;
  String? _startingDeviceId;
  Duration? _scrubPosition;
  MediaTask? _createdRemoteTask;
  bool _ownsRemoteTask = false;
  bool _commandBusy = false;

  DlnaCastController get cast => widget.controller ?? widget.app.mediaCast;
  bool get _hasSource => widget.task != null || widget.candidate != null;

  Future<void> _discover() async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final devices = await widget.discovery.discover();
      if (!mounted) return;
      setState(() => _devices = devices);
      if (devices.isEmpty) {
        setState(() => _error = '局域网内没有发现可用的 DLNA 接收端');
      }
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.dlna',
        context: 'discover',
        stack: stack,
      );
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<MediaTask> _ensureTask() async {
    final provided = widget.task;
    if (provided != null) return provided;
    final candidate = widget.candidate;
    if (candidate == null) throw StateError('缺少可投屏媒体');
    final existing = widget.app.mediaTasks.taskForCandidate(candidate);
    final created = _createdRemoteTask ??= widget.app.mediaTasks.create(
      candidate,
    );
    _ownsRemoteTask = existing == null || existing.id != created.id;
    return created;
  }

  Future<({Uri url, String mime, String title, File? localFile, File? hls})>
  _resolveSource(MediaTask task) async {
    final candidate = widget.candidate;
    if (candidate != null) {
      final local = await widget.app.mediaPlaybackFile(task);
      if (local == null) {
        return (
          url: candidate.mediaUrl,
          mime: candidate.effectiveMime,
          title: candidate.title,
          localFile: null,
          hls: null,
        );
      }
      return _localSource(task, local);
    }
    final local = await widget.app.mediaPlaybackFile(task);
    if (local == null) throw StateError('该媒体没有可投屏的本地文件');
    return _localSource(task, local);
  }

  ({Uri url, String mime, String title, File? localFile, File? hls})
  _localSource(MediaTask task, File local) {
    final isHls = local.path.toLowerCase().endsWith('.m3u8');
    return (
      url: local.uri,
      mime: isHls ? 'application/vnd.apple.mpegurl' : 'video/mp4',
      title: task.displayName,
      localFile: isHls ? null : local,
      hls: isHls ? local : null,
    );
  }

  Future<void> _startCast(CastDevice device) async {
    if (_startingDeviceId != null || !_hasSource) return;
    setState(() {
      _startingDeviceId = device.id;
      _error = null;
    });
    var retained = false;
    MediaTask? task;
    try {
      task = await _ensureTask();
      if (widget.task == null && _ownsRemoteTask) {
        cast.markTemporaryTask(task.id);
      }
      widget.app.mediaTasks.retain(task.id);
      retained = true;
      late final ({
        Uri url,
        String mime,
        String title,
        File? localFile,
        File? hls,
      })
      source;
      try {
        source = await _resolveSource(task);
      } on PlatformException catch (error) {
        throw StateError(
          '读取投屏媒体失败（${error.code}）：${error.message ?? '系统媒体文件不可用'}',
        );
      }
      if (!mounted) return;
      await _castSource(device, task, source);
      final castSessionId = cast.active?.id;
      final initial = widget.initialPosition;
      if (initial != null) {
        try {
          await cast.seek(initial);
        } catch (error) {
          if (mounted) {
            showShortToast(context, '初始进度未能同步：${friendlyError(error)}');
          }
        }
      }
      final callback = widget.onCastStarted;
      if (callback != null && mounted && cast.active?.id == castSessionId) {
        try {
          await callback();
        } catch (error) {
          if (mounted) {
            showShortToast(context, '本机播放器未能暂停：${friendlyError(error)}');
          }
        }
      }
      if (mounted) showShortToast(context, '已连接到 ${device.name}');
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.dlna',
        context: 'start',
        stack: stack,
      );
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (retained) widget.app.mediaTasks.release(task!.id);
      if (widget.task == null && _ownsRemoteTask && task != null) {
        await widget.app.cleanupTemporaryCastTask(task.id);
        _createdRemoteTask = null;
        _ownsRemoteTask = false;
      }
      if (mounted) setState(() => _startingDeviceId = null);
    }
  }

  Future<void> _castSource(
    CastDevice device,
    MediaTask task,
    ({Uri url, String mime, String title, File? localFile, File? hls}) source,
  ) async {
    try {
      await cast.cast(
        device: device,
        mediaTaskId: task.id,
        mediaUrl: source.url,
        localFile: source.localFile,
        localHlsPlaylist: source.hls,
        mime: source.mime,
        title: source.title,
      );
    } on DlnaUnsupportedFormatException catch (error) {
      final remoteIsHls =
          source.mime.toLowerCase().contains('mpegurl') ||
          source.url.path.toLowerCase().endsWith('.m3u8') ||
          source.url.path.toLowerCase().endsWith('.m3u');
      if (!error.requiresMp4 || (source.hls == null && !remoteIsHls)) rethrow;
      var localHls = source.hls;
      if (localHls == null) {
        final candidate =
            widget.candidate ??
            await widget.app.db.mediaCandidate(task.candidateId);
        if (candidate == null || !candidate.isHls) {
          throw StateError('接收设备不支持 HLS，且当前媒体没有可转换的本地缓存');
        }
        await widget.app.mediaDownloads.start(task, candidate);
        localHls = await widget.app.mediaPlaybackFile(
          task,
          preferExported: false,
        );
      }
      if (localHls == null || !localHls.path.toLowerCase().endsWith('.m3u8')) {
        throw StateError('接收设备不支持 HLS，且媒体缓存未准备完成');
      }
      // Keep the beta5 behavior: prepare a private playback MP4 only for
      // this cast attempt and never open the configured export directory.
      try {
        await widget.app.exportMediaTask(
          task,
          deliverToConfiguredDirectory: false,
        );
      } on PlatformException catch (error) {
        throw StateError(
          '投屏前转换 MP4 失败（${error.code}）：${error.message ?? '导出组件不可用'}',
        );
      }
      final exported = await widget.app.mediaLibrary.localFile(task.id);
      if (exported == null) {
        throw StateError('该设备不支持 HLS，且本地 MP4 导出失败');
      }
      if (!mounted) return;
      await cast.cast(
        device: device,
        mediaTaskId: task.id,
        mediaUrl: exported.uri,
        localFile: exported,
        mime: 'video/mp4',
        title: task.displayName,
      );
    }
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    if (_commandBusy) return null;
    setState(() {
      _commandBusy = true;
      _error = null;
    });
    try {
      return await action();
    } on DlnaOptionalCommandUnsupportedException catch (error) {
      if (mounted) showShortToast(context, error.message);
    } catch (error, stack) {
      AppErrorLogger.capture(
        error,
        module: 'media.dlna',
        context: 'command',
        stack: stack,
      );
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _commandBusy = false);
    }
    return null;
  }

  String _stateLabel(CastSessionState? state) => switch (state) {
    CastSessionState.discovering => '正在发现设备',
    CastSessionState.connecting => '正在连接',
    CastSessionState.settingMedia => '正在准备媒体',
    CastSessionState.playing => '播放中',
    CastSessionState.paused => '已暂停',
    CastSessionState.stopped => '已停止',
    CastSessionState.failed => '投屏失败',
    null => '未投屏',
  };

  String _duration(Duration? value) {
    if (value == null) return '--:--';
    final seconds = value.inSeconds;
    final h = seconds ~/ 3600;
    final m = (seconds ~/ 60) % 60;
    final s = seconds % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Widget _devicePanel(DlnaCastStatus status) => SiteLensPanel(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        ListTile(
          leading: const Icon(Icons.cast_outlined),
          title: const Text('选择接收设备'),
          subtitle: Text(_searching ? '正在搜索局域网设备…' : '搜索并选择电视、盒子或其他 DLNA 播放器'),
          trailing: IconButton(
            tooltip: '搜索 DLNA 设备',
            icon: _searching
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _searching ? null : _discover,
          ),
        ),
        if (_devices.isNotEmpty)
          for (final device in _devices) ...[
            const Divider(height: 1, indent: 18, endIndent: 18),
            ListTile(
              leading: Icon(
                status.device?.id == device.id
                    ? Icons.cast_connected
                    : Icons.tv_outlined,
              ),
              title: Text(device.name),
              subtitle: Text(device.model ?? device.address.host),
              trailing: _startingDeviceId == device.id
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: _startingDeviceId == null && _hasSource && !status.active
                  ? () => unawaited(_startCast(device))
                  : null,
            ),
          ],
      ],
    ),
  );

  Widget _controls(DlnaCastStatus status) {
    final session = status.session;
    final playing = session?.state == CastSessionState.playing;
    final position = _scrubPosition ?? status.position ?? Duration.zero;
    final duration = status.duration ?? Duration.zero;
    final canSeek = status.canSeek && !_commandBusy;
    return SiteLensPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cast_connected, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status.device?.name ?? 'DLNA 投屏',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(_stateLabel(session?.state)),
            ],
          ),
          if (duration > Duration.zero) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text(_duration(position)), Text(_duration(duration))],
            ),
            Slider(
              min: 0,
              max: duration.inMilliseconds.toDouble(),
              value: position.inMilliseconds
                  .clamp(0, duration.inMilliseconds)
                  .toDouble(),
              onChanged: canSeek
                  ? (value) => setState(
                      () => _scrubPosition = Duration(
                        milliseconds: value.round(),
                      ),
                    )
                  : null,
              onChangeEnd: canSeek
                  ? (value) {
                      _scrubPosition = null;
                      unawaited(
                        _run(
                          () =>
                              cast.seek(Duration(milliseconds: value.round())),
                        ),
                      );
                    }
                  : null,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '快退 10 秒',
                icon: const Icon(Icons.replay_10),
                onPressed: canSeek
                    ? () => unawaited(
                        _run(() => cast.seekBy(const Duration(seconds: -10))),
                      )
                    : null,
              ),
              IconButton(
                tooltip: playing ? '暂停' : '播放',
                icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                iconSize: 42,
                onPressed: !status.controllable || _commandBusy
                    ? null
                    : () => unawaited(
                        _run(() => playing ? cast.pause() : cast.resume()),
                      ),
              ),
              IconButton(
                tooltip: '快进 10 秒',
                icon: const Icon(Icons.forward_10),
                onPressed: canSeek
                    ? () => unawaited(
                        _run(() => cast.seekBy(const Duration(seconds: 10))),
                      )
                    : null,
              ),
            ],
          ),
          const Divider(height: 20),
          Row(
            children: [
              const Icon(Icons.volume_down_outlined, size: 20),
              Expanded(
                child: Text(
                  status.volumeSupported && status.volume != null
                      ? '设备音量 ${status.volume}%'
                      : '设备不支持音量控制',
                ),
              ),
              IconButton(
                tooltip: '音量减小',
                icon: const Icon(Icons.remove),
                onPressed: status.volumeSupported && !_commandBusy
                    ? () => unawaited(_run(() => cast.adjustVolume(-5)))
                    : null,
              ),
              IconButton(
                tooltip: '音量增大',
                icon: const Icon(Icons.add),
                onPressed: status.volumeSupported && !_commandBusy
                    ? () => unawaited(_run(() => cast.adjustVolume(5)))
                    : null,
              ),
              IconButton(
                tooltip: '停止投屏',
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: session == null
                    ? null
                    : () => unawaited(
                        _run(() async {
                          await cast.stop();
                          if (mounted) setState(() => _devices = const []);
                        }),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: cast,
    builder: (context, _) {
      final status = cast.status;
      return SiteLensPageScaffold(
        title: 'DLNA 投屏',
        actions: [
          if (status.active)
            IconButton(
              tooltip: '刷新投屏状态',
              icon: const Icon(Icons.sync),
              onPressed: status.controllable && !_commandBusy
                  ? () => unawaited(_run(cast.refresh))
                  : null,
            ),
        ],
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            SiteLensMetrics.pagePadding,
            12,
            SiteLensMetrics.pagePadding,
            32,
          ),
          children: [
            if (_error != null) ...[
              SiteLensErrorBanner(
                text: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
              const SizedBox(height: 12),
            ],
            if (status.active) ...[
              _controls(status),
              const SizedBox(height: SiteLensMetrics.itemGap),
            ],
            if (status.session != null && !status.active) ...[
              SiteLensPanel(
                child: Text(
                  status.session!.errorCode ??
                      _stateLabel(status.session!.state),
                ),
              ),
              const SizedBox(height: SiteLensMetrics.itemGap),
            ],
            _devicePanel(status),
          ],
        ),
      );
    },
  );
}
