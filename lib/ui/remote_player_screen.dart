import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../media/media_service.dart';
import '../media/remote_episode_source.dart';
import '../media/remote_playback_controller.dart';
import '../media/remote_playback_failure.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_util.dart';

/// 播放页对外的全部去向，由 `AppController` 接上。
///
/// 播放页本身不认识控制器、适配器或原生通道：它拿一集、一个标题、一个
/// [RemotePlaybackHost]，剩下的都由播放器控制器负责。
class RemotePlayerScreen extends StatefulWidget {
  const RemotePlayerScreen({
    super.key,
    required this.host,
    required this.candidate,
    required this.title,
    required this.episodeNumber,
    this.source,
    this.lineId,
    this.qualityLabel,
    this.audioLabel,
    this.continueWatchingMs = 0,
    this.onEpisodeChanged,
    this.profileId,
  });

  final RemotePlaybackHost host;
  final MediaCandidate candidate;
  final String title;
  final String episodeNumber;
  final RemoteEpisodeSource? source;
  final String? lineId;
  final String? qualityLabel;
  final String? audioLabel;
  final int continueWatchingMs;
  final void Function(String episode, int positionMs)? onEpisodeChanged;

  /// 这一部剧所属的站点档案；换集与失败重开都带给宿主（ADR-0009）。
  final int? profileId;

  @override
  State<RemotePlayerScreen> createState() => _RemotePlayerScreenState();
}

class _RemotePlayerScreenState extends State<RemotePlayerScreen> {
  late final RemotePlaybackController _controller = RemotePlaybackController(
    host: widget.host,
    title: widget.title,
    episodeNumber: widget.episodeNumber,
    initial: widget.candidate,
    source: widget.source,
    lineId: widget.lineId,
    qualityLabel: widget.qualityLabel,
    audioLabel: widget.audioLabel,
    continueWatching: widget.continueWatchingMs,
    profileId: widget.profileId,
    onEpisodeChanged: (episode, position) =>
        widget.onEpisodeChanged?.call(episode, position),
  );

  /// 可选的倍速档位。与媒体任务里的播放器同一组取值。
  static const _speeds = <double>[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3];

  bool _controlsVisible = true;
  bool _gestureHintVisible = false;
  Timer? _hideTimer;
  Timer? _hintTimer;
  String? _gestureHint;
  bool _exiting = false;

  /// 拖动进度条时的预览位置。松手才真正 seek，拖动期间不追着原生跑。
  int? _scrubPosition;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
    _scheduleHide();
  }

  /// 点开就播：不等任何超时，先把原生会话开起来。
  Future<void> _start() async {
    try {
      await _controller.start();
    } catch (error) {
      if (!mounted) return;
      // 打开失败不是远程归因：会话根本没起来，没有 errorCode 可读。
      setState(() {});
      showError(context, error);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    // stopAndDispose 会关掉原生会话并释放订阅；再调一次 dispose 会把它的
    // 收尾切成两半（关会话的 future 还没跑完就先被销毁）。
    unawaited(_controller.stopAndDispose());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    // 旋转锁定交还给系统：离开播放页之后，读文章不该还锁在横屏。
    unawaited(SystemChrome.setPreferredOrientations(const []));
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_controlsVisible) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
      unawaited(_applySystemUi());
    });
    unawaited(_applySystemUi());
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleHide();
  }

  Future<void> _applySystemUi() => SystemChrome.setEnabledSystemUIMode(
    _controlsVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
  );

  void _showHint(String text) {
    _hintTimer?.cancel();
    setState(() {
      _gestureHint = text;
      _gestureHintVisible = true;
    });
    _hintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _gestureHintVisible = false);
    });
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    _hideTimer?.cancel();
    await _controller.stopAndDispose();
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _setSpeed(double speed) async {
    await _controller.setSpeed(speed);
    _showHint(_speedLabel(speed));
    _scheduleHide();
  }

  Future<void> _retryCurrent() async {
    await _controller.retryCurrent();
    if (!mounted) return;
    _scheduleHide();
  }

  Future<void> _switch(int offset) async {
    await _controller.switchBy(offset);
    final error = _controller.openError;
    if (!mounted) return;
    if (error != null) {
      _showHint(error);
    } else {
      _showHint(_controller.currentEpisode);
    }
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onDoubleTap: () => unawaited(_controller.toggle()),
                  onLongPressStart: (_) =>
                      unawaited(_controller.setSpeed(2).whenComplete(() {})),
                  onLongPressEnd: (_) => unawaited(
                    _controller.setSpeed(
                      _controller.speed == 2 ? 1 : _controller.speed,
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) => RemoteVideoViewport(
                      session: _controller.session,
                      availableWidth: constraints.maxWidth,
                      availableHeight: constraints.maxHeight,
                      placeholder: _placeholder(),
                    ),
                  ),
                ),
                if (_controller.session?.state ==
                        NativePlaybackState.buffering ||
                    _controller.session?.state == NativePlaybackState.preparing)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                if (_gestureHintVisible && _gestureHint != null)
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
                if (_controller.failure != null ||
                    _controller.openError != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 132,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _failureNotice(_controller.failure),
                    ),
                  ),
                if (_controlsVisible) ..._chrome(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    final error = _controller.openError;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_outlined, color: Colors.white70, size: 40),
            const SizedBox(height: 12),
            Text(
              '${_controller.title} · ${_controller.currentEpisode}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _controller.dismissOpenError,
                child: const Text('知道了'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 远程失败的四类结局各带一个动作：凭证失效去登录、清单失效重试、分片
  /// 失败建议下载该集、网络失败只留文案。这里不自己判定种类。
  Widget _failureNotice(RemoteFailurePlan? plan) {
    final message = plan?.message ?? _controller.openError ?? '';
    final action = plan == null ? null : _suggestedAction(plan);
    return SiteLensGlassSurface(
      role: SiteLensSurfaceRole.platformView,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _failureIcon(plan),
                size: 20,
                color: SiteLensColors.of(context).warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: '关闭提示',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _controller.dismissFailure();
                  _controller.dismissOpenError();
                },
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          if (action != null)
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  _controller.dismissFailure();
                  action.run();
                },
                child: Text(action.label),
              ),
            ),
        ],
      ),
    );
  }

  static IconData _failureIcon(RemoteFailurePlan? plan) =>
      switch (plan?.failure.kind) {
        RemoteFailureKind.credentialRejected => Icons.key_off_outlined,
        RemoteFailureKind.manifestUnavailable => Icons.link_off,
        RemoteFailureKind.segmentFailed => Icons.download_for_offline_outlined,
        RemoteFailureKind.network => Icons.wifi_off_outlined,
        null => Icons.error_outline,
      };

  /// 失败归因给出的下一步。预算用尽之后仍然给建议，但重试按钮不再出现——
  /// 一个点了也没用的重试比没有重试更糟。
  ({String label, void Function() run})? _suggestedAction(
    RemoteFailurePlan plan,
  ) {
    switch (plan.action) {
      case RemoteFailureAction.refreshCredentialAndReopen:
        return (label: '重新尝试', run: () => unawaited(_retryCurrent()));
      case RemoteFailureAction.reloadManifestAndReopen:
        if (!plan.failure.exhausted) return null;
        return (label: '重试', run: () => unawaited(_retryCurrent()));
      case RemoteFailureAction.suggestDownload:
        // 下载是独立动作（T14）。播放页不建任务，只把用户推向那一集。
        return (label: '回到选集', run: () => unawaited(_exit()));
      case RemoteFailureAction.keepNetworkMessage:
        return null;
    }
  }

  List<Widget> _chrome() => [
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
            onPressed: _exit,
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [_speedMenu()]),
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
          Text(
            '${_controller.title} · ${_controller.currentEpisode}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 4),
          ValueListenableBuilder<int>(
            valueListenable: _controller.position,
            builder: (context, positionMs, _) => _progress(positionMs),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一集',
                color: Colors.white,
                icon: const Icon(Icons.skip_previous),
                onPressed: _controller.switching || _controller.source == null
                    ? null
                    : () => unawaited(_switch(-1)),
              ),
              IconButton(
                tooltip:
                    _controller.session?.state == NativePlaybackState.playing
                    ? '暂停'
                    : '播放',
                color: Colors.white,
                icon: Icon(
                  _controller.session?.state == NativePlaybackState.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 40,
                ),
                onPressed: _controller.session == null
                    ? null
                    : () => unawaited(_controller.toggle()),
              ),
              IconButton(
                tooltip: '下一集',
                color: Colors.white,
                icon: const Icon(Icons.skip_next),
                onPressed: _controller.switching || _controller.source == null
                    ? null
                    : () => unawaited(_switch(1)),
              ),
            ],
          ),
        ],
      ),
    ),
  ];

  Widget _speedMenu() => PopupMenuButton<double>(
    tooltip: '播放速度 ${_speedLabel(_controller.speed)}',
    icon: const Icon(Icons.speed, color: Colors.white),
    initialValue: _speeds.contains(_controller.speed)
        ? _controller.speed
        : null,
    onSelected: (speed) => unawaited(_setSpeed(speed)),
    itemBuilder: (_) => [
      for (final speed in _speeds)
        PopupMenuItem(value: speed, child: Text(_speedLabel(speed))),
    ],
  );

  Widget _progress(int positionMs) {
    final session = _controller.session;
    final duration = math.max(1, session?.durationMs ?? 0);
    final shown = _scrubPosition ?? positionMs;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                formatMediaDuration(shown),
                style: const TextStyle(
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                formatMediaDuration(session?.durationMs ?? 0),
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
          max: duration.toDouble(),
          value: shown.clamp(0, duration).toDouble(),
          onChanged: (value) => setState(() => _scrubPosition = value.round()),
          onChangeEnd: (value) {
            final target = value.round();
            setState(() => _scrubPosition = null);
            unawaited(_controller.seek(Duration(milliseconds: target)));
          },
        ),
      ],
    );
  }
}

String _speedLabel(double speed) {
  final text = speed == speed.roundToDouble()
      ? speed.toStringAsFixed(0)
      : speed.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
  return '${text}x';
}

/// 原生纹理的取景框：按内容比例装进可用区域，不裁切也不压扁。
///
/// 比例来自原生会话的 `videoWidth` / `videoHeight`；还没拿到时按 16:9 留位，
/// 不先撑满再跳变。竖屏短剧（9:16）与横屏（16:9）走同一套算式，方向变化只
/// 改变可用区域，从不改变内容比例。可用区域显式传入，这样取景结果在任何
/// 父级约束下都可预期，也能被单测直接断言。
class RemoteVideoViewport extends StatelessWidget {
  const RemoteVideoViewport({
    super.key,
    required this.session,
    required this.availableWidth,
    required this.availableHeight,
    this.fill = false,
    this.placeholder,
    this.quarterTurns = 0,
  });

  final NativePlaybackSession? session;
  final double availableWidth;
  final double availableHeight;

  /// true 时用「填充」而不是「适配」：放大到盖满，仍然保持比例。
  final bool fill;

  /// 还没有原生画面时显示的东西（错误说明、加载占位）。
  final Widget? placeholder;

  /// 用户手动旋转画面的角度，90° 的整数倍。
  final int quarterTurns;

  static const _fallbackRatio = 16 / 9;

  /// 内容比例：原生给的宽高比，还没有解码尺寸时按 16:9。
  double get sourceRatio {
    final current = session;
    if (current == null ||
        current.videoWidth <= 0 ||
        current.videoHeight <= 0) {
      return _fallbackRatio;
    }
    return current.videoWidth / current.videoHeight;
  }

  @override
  Widget build(BuildContext context) {
    final textureId = session?.textureId;
    if (textureId == null) {
      return Center(child: placeholder ?? const SizedBox.shrink());
    }
    final turns = quarterTurns % 4;
    final rotated = turns.isOdd;
    // 旋转 90° 时内容的长边落在可用区域的高上。
    final boxWidth = rotated ? availableHeight : availableWidth;
    final boxHeight = rotated ? availableWidth : availableHeight;
    final size = fittedSize(
      boxWidth: boxWidth,
      boxHeight: boxHeight,
      sourceRatio: sourceRatio,
      fill: fill,
    );
    return ClipRect(
      child: Center(
        child: SizedBox(
          width: rotated ? size.height : size.width,
          height: rotated ? size.width : size.height,
          child: RotatedBox(
            quarterTurns: turns,
            child: Texture(textureId: textureId),
          ),
        ),
      ),
    );
  }

  /// 把一个比例为 [sourceRatio] 的画面装进 [boxWidth] × [boxHeight]。
  ///
  /// 适配（[fill] 为 false）：整幅可见，留黑边；填充（true）：盖满，可能裁掉
  /// 边缘。两条路径都只缩放、不改变比例，所以画面既不会被裁切也不会被压扁。
  static Size fittedSize({
    required double boxWidth,
    required double boxHeight,
    required double sourceRatio,
    bool fill = false,
  }) {
    if (boxWidth <= 0 || boxHeight <= 0 || sourceRatio <= 0) {
      return Size(
        boxWidth.clamp(0, double.infinity),
        boxHeight.clamp(0, double.infinity),
      );
    }
    final boxRatio = boxWidth / boxHeight;
    if (fill) {
      return boxRatio > sourceRatio
          ? Size(boxWidth, boxWidth / sourceRatio)
          : Size(boxHeight * sourceRatio, boxHeight);
    }
    return boxRatio > sourceRatio
        ? Size(boxHeight * sourceRatio, boxHeight)
        : Size(boxWidth, boxWidth / sourceRatio);
  }
}

/// 一集在播放页标题里的名字：候选带着集号就用它，没有就用目录给的标题。
String episodeLabelFor(MediaCandidate candidate, {String? fallbackTitle}) {
  final number = candidate.episodeNumber;
  if (number != null) return '第 $number 集';
  final title = fallbackTitle?.trim();
  return title == null || title.isEmpty ? '当前选集' : title;
}
