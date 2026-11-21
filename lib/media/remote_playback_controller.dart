import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/site_adapter.dart';
import 'media_service.dart';
import 'remote_episode_source.dart';
import 'remote_playback_failure.dart';

/// 一次远程播放里「点开就播」需要的全部去向。
///
/// 生产环境由 `AppController` 接上；测试里换成假实现，播放页因此不需要原生
/// 通道也能把所有交互走一遍。
abstract interface class RemotePlaybackHost {
  /// 打开一个远程候选（凭证注入、缓存、凭证租约都由这一层处理）。
  Future<NativePlaybackSession> openRemote(MediaCandidate candidate);

  /// 原生会话快照的推送流。订阅方负责在销毁时取消。
  Stream<NativePlaybackSession> get nativeStates;

  Future<NativePlaybackSession> play(String sessionId);
  Future<NativePlaybackSession> pause(String sessionId);
  Future<NativePlaybackSession> seek(Duration position, String sessionId);
  Future<NativePlaybackSession> setSpeed(double speed, String sessionId);
  Future<NativePlaybackSession> close(String sessionId);

  /// 认一次远程失败。返回 null 表示这个错误码不是远程归因。
  ///
  /// [retry] 是「再开一次」的动作，调用方**显式**带给它：这是 ADR-0005
  /// 要求的另一半，重试从不静默。
  RemoteFailurePlan? observeRemoteFailure(
    NativePlaybackSession session, {
    void Function()? retry,
  });

  /// 用户点掉远程失败提示。
  void dismissRemoteFailure();
}

/// 播放器自己的状态：排队、换集、倍速、失败、播完。
///
/// 它不持有任何原生状态机：原生会话的唯一真相是 [NativePlaybackSession]，
/// 这里只记「播放器此刻在放谁」以及「下一集从哪来」。
///
/// 跳集与自动连播共用一个 [switchToEpisode]：先拿到下一集的候选，再开新的
/// 原生会话，最后才关掉旧的。顺序是刻意的——旧会话在新会话就绪之前不动，
/// 失败时可以原样退回，用户看到的是一次短暂停顿，不是黑屏。
class RemotePlaybackController extends ChangeNotifier {
  RemotePlaybackController({
    required RemotePlaybackHost host,
    required this.title,
    required this.episodeNumber,
    required this.initial,
    this.source,
    this.lineId,
    this.qualityLabel,
    this.audioLabel,
    this.continueWatching = 0,
    this.onEpisodeChanged,
  }) : _host = host {
    _states = host.nativeStates.listen(_onNativeState);
  }

  final RemotePlaybackHost _host;
  late final StreamSubscription<NativePlaybackSession> _states;

  /// 这一部剧的名字。播放页拿它做标题；它不属于任何一集。
  final String title;

  /// 这一集在目录里的名字，例如「第 3 集」。
  final String episodeNumber;

  /// 播放页打开时交给播放器的那份候选。它是第一集，也是「换集失败退回」时
  /// 的原样参数。
  final MediaCandidate initial;

  /// 下一集从哪里来；为 null 表示这部剧只有这一集，不连播也不跳集。
  final RemoteEpisodeSource? source;
  final String? lineId;
  final String? qualityLabel;
  final String? audioLabel;

  /// 「继续观看」的起点。**不落库**：追剧记录是另一件事（T12），这里只把
  /// 调用方手里已有的位置用上，没有就从头上播。
  final int continueWatching;

  /// 当前这一集换了之后的通知，参数是（集号标签，是不是用户自己跳的）。
  final void Function(String episode, int positionMs)? onEpisodeChanged;

  NativePlaybackSession? _session;
  NativePlaybackSession? get session => _session;

  /// 当前正在放的那一集；[episodeNumber] 只是打开时的那一集。
  String _currentEpisode = '';
  String get currentEpisode =>
      _currentEpisode.isEmpty ? episodeNumber : _currentEpisode;

  MediaCandidate get currentCandidate => _candidate ?? initial;
  MediaCandidate? _candidate;

  /// 倍速跟着播放器走，不跟着会话走：换集、重开都不重置它。
  double _speed = 1;
  double get speed => _speed;

  RemoteFailurePlan? _failure;
  RemoteFailurePlan? get failure => _failure;

  /// 打开这一集（第一集或换集）失败时的说明。它与 [failure] 不混：那是原生
  /// 会话里的远程失败，这是「根本没开起来」。
  String? _openError;
  String? get openError => _openError;

  /// 目录没有更多集了。自动连播走到这里就停下来，不假装还有下一集。
  bool _reachedLast = false;
  bool get reachedLastEpisode => _reachedLast;

  bool _switching = false;
  bool get switching => _switching;

  final _position = ValueNotifier<int>(0);

  /// 当前播放位置。界面用 ListenableBuilder 订阅它，不随每一帧重建整页。
  ValueListenable<int> get position => _position;

  bool _completionHandled = false;
  bool _disposed = false;

  /// 打开第一集。返回后播放页可以立即显示画面占位或原生画面。
  Future<void> start() async {
    await _open(initial, autoPlay: true);
  }

  Future<void> _open(
    MediaCandidate candidate, {
    required bool autoPlay,
    bool isSwitch = false,
  }) async {
    _openError = null;
    _failure = null;
    final next = await _host.openRemote(candidate);
    if (_disposed) {
      // 打开期间页面就走了：新会话不能留在后台占着音频。
      try {
        await _host.close(next.id);
      } catch (_) {
        // 原生服务可能已经随页面一起消失。
      }
      return;
    }
    _candidate = candidate;
    _currentEpisode = _episodeLabelOf(candidate);
    _session = next;
    _completionHandled = false;
    _reachedLast = false;
    _position.value = continueWatching > 0 && !isSwitch ? continueWatching : 0;
    notifyListeners();
    // 换集时把倍速带过去：原生开新会话默认 1x，用户的 2x 不该被吃掉。
    if (_speed != 1 && next.id.isNotEmpty) {
      await _host.setSpeed(_speed, next.id);
    }
    if (continueWatching > 0 && !isSwitch && next.id.isNotEmpty) {
      await _host.seek(Duration(milliseconds: continueWatching), next.id);
    }
    if (autoPlay && next.id.isNotEmpty) await play();
  }

  String _episodeLabelOf(MediaCandidate candidate) {
    final number = candidate.episodeNumber;
    if (number == null) return currentEpisode;
    return '第 $number 集';
  }

  void _onNativeState(NativePlaybackSession session) {
    if (_disposed) return;
    final current = _session;
    if (current == null) return;
    // 别的会话（本地播放、上一集还没关掉的那个）的快照不归这里管。
    if (session.id.isNotEmpty && current.id.isNotEmpty) {
      if (session.id != current.id) return;
    }
    _session = session;
    if (session.positionMs > 0 && !_switching) {
      _position.value = session.positionMs;
    }
    // 原生记住的是它自己的倍速；用户刚设的那一档在换集后可能还没生效回去，
    // 所以只把会话里的倍速当作「某个时刻的事实」，不以它覆盖播放器的选择。
    if (session.state == NativePlaybackState.failed) {
      _handleRemoteFailure(session);
    }
    if (session.state == NativePlaybackState.completed) {
      unawaited(_onCompleted());
    }
    notifyListeners();
  }

  void _handleRemoteFailure(NativePlaybackSession session) {
    final plan = _host.observeRemoteFailure(session, retry: _retryFor(session));
    if (plan == null) return;
    _failure = plan;
  }

  /// 这一类的重开动作。凭证失效与清单失效共用「用同一个候选再开一次」，
  /// 预算由失败链自己记（每段会话每类一次）。
  void Function()? _retryFor(NativePlaybackSession session) {
    final failure = RemotePlaybackFailure.classify(session);
    if (failure == null) return null;
    if (!failure.reopensEpisode) return null;
    return () => unawaited(_reopenSameEpisode());
  }

  Future<void> _reopenSameEpisode() async {
    try {
      await _open(currentCandidate, autoPlay: true);
    } catch (error) {
      if (_disposed) return;
      _openError = remoteOpenFailureText(error);
      notifyListeners();
    }
  }

  /// 用户点了失败归因给出的下一步：用当前这一集的同一份候选再开一次。
  ///
  /// 这是**用户显式**的重试，和 [RemoteFailurePlan.retry] 那条自动重试链各自
  /// 计数——重试从不静默，但也从不由用户去猜预算还剩多少。
  Future<void> retryCurrent() async {
    if (_switching) return;
    _switching = true;
    _failure = null;
    _openError = null;
    notifyListeners();
    try {
      await _reopenSameEpisode();
    } finally {
      _switching = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> play() async {
    final id = _session?.id;
    if (id == null || id.isEmpty) return;
    await _host.play(id);
  }

  Future<void> pause() async {
    final id = _session?.id;
    if (id == null || id.isEmpty) return;
    await _host.pause(id);
  }

  /// 双击 / 播放按钮用：原生说自己在播就暂停，否则播放。
  ///
  /// 判定读的是原生快照，不是本地记的意图；拔耳机之后原生会自己变成
  /// paused（媒体会话的 audio-becoming-noisy 处置），这里因此也会显示成暂停。
  Future<void> toggle() async {
    final state = _session?.state;
    if (state == NativePlaybackState.playing ||
        state == NativePlaybackState.buffering) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    final id = _session?.id;
    if (id == null || id.isEmpty) return;
    _position.value = position.inMilliseconds;
    await _host.seek(position, id);
  }

  /// 用户选的倍速：先记住，再交给原生。原生报错不吞掉用户的选择。
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    final id = _session?.id;
    if (id != null && id.isNotEmpty) await _host.setSpeed(speed, id);
    notifyListeners();
  }

  /// 手动跳集：±1 集，或直接到某一集。
  Future<void> switchBy(int offset) => _switchToOffset(offset, byUser: true);

  /// 下一集。没有目录来源时不动作，把理由留在 [openError]。
  Future<void> playNext() async {
    if (source == null) {
      _openError = '这一部只有当前这一集';
      notifyListeners();
      return;
    }
    await _switchToOffset(1, byUser: true);
  }

  Future<void> playPrevious() async {
    if (source == null) {
      _openError = '这一部只有当前这一集';
      notifyListeners();
      return;
    }
    await _switchToOffset(-1, byUser: true);
  }

  Future<void> _switchToOffset(int offset, {required bool byUser}) async {
    if (_switching) return;
    final target = _targetEpisode(offset);
    if (target == null) {
      _reachedLast = true;
      if (byUser) _openError = offset > 0 ? '已经是最后一集' : '已经是第一集';
      notifyListeners();
      return;
    }
    _switching = true;
    notifyListeners();
    final previous = _session;
    try {
      final candidate = await _resolve(target);
      // 先开新的，成功了才关旧的：任何一步失败都还站在原来那一集上。
      await _open(candidate, autoPlay: true, isSwitch: true);
      await _closeQuietly(previous);
      _openError = null;
      onEpisodeChanged?.call(currentEpisode, 0);
    } catch (error) {
      // 换集失败：原会话没动，把失败说清楚，用户还停在这一集。
      // 但「目录里没有下一集」不是换集失败，而是到头了——用户手动点下一集
      // 时才把原因说出来，自动连播则安静停下。
      final isLast =
          error is SiteAdapterError &&
          error.kind == SiteAdapterErrorKind.notFound;
      _reachedLast = isLast;
      if (!isLast || byUser) {
        _openError = switch (error) {
          SiteAdapterError() => '第 $target 集取不到：${error.message}',
          _ => remoteOpenFailureText(error),
        };
      }
    } finally {
      _switching = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 自动连播：播完就下一集。它走的是同一个 [switchToOffset]，所以倍速、
  /// 线路与清晰度全都沿用。
  Future<void> _onCompleted() async {
    if (_completionHandled) return;
    _completionHandled = true;
    if (source == null) {
      _reachedLast = true;
      notifyListeners();
      return;
    }
    await _switchToOffset(1, byUser: false);
  }

  Future<MediaCandidate> _resolve(int episodeNumber) async {
    final fromCatalog = source;
    if (fromCatalog != null) {
      return fromCatalog.resolve(episodeNumber, CancellationSignal());
    }
    throw SiteAdapterError(SiteAdapterErrorKind.notFound, '这一部没有目录来源');
  }

  int? _targetEpisode(int offset) {
    final current = currentCandidate.episodeNumber;
    if (current == null) return null;
    final target = current + offset;
    return target < 1 ? null : target;
  }

  Future<void> _closeQuietly(NativePlaybackSession? session) async {
    if (session == null || session.id.isEmpty) return;
    if (identical(session, _session)) return;
    try {
      await _host.close(session.id);
    } catch (_) {
      // 关闭旧会话失败不影响已经在放的新会话。
    }
  }

  /// 用户点掉远程失败提示。
  void dismissFailure() {
    if (_failure == null) return;
    _failure = null;
    _host.dismissRemoteFailure();
    notifyListeners();
  }

  /// 用户点掉「这一集没开起来」的说明。
  void dismissOpenError() {
    if (_openError == null) return;
    _openError = null;
    notifyListeners();
  }

  /// 页面离开：关会话、取消订阅、释放 notifier。
  ///
  /// 顺序是刻意的：先让监听者看到「已停止」，再释放 notifier，最后去关原生
  /// 会话。关会话是异步的，若放在 [super.dispose] 之前，就会在页面已经拆掉
  /// 之后才回头碰控制器。会话一旦交出去就一定会被关，与页面是否还活着无关。
  Future<void> stopAndDispose() async {
    if (_disposed) {
      await _closeQuietly(_session);
      _session = null;
      return;
    }
    _disposed = true;
    final current = _session;
    _session = null;
    await _states.cancel();
    _position.dispose();
    notifyListeners();
    super.dispose();
    await _closeQuietly(current);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final current = _session;
    _session = null;
    unawaited(_states.cancel());
    _position.dispose();
    super.dispose();
    unawaited(_closeQuietly(current));
  }
}

/// 打开失败时用户能读懂的那句话。远程原生失败读归因，其它读既有文案。
String remoteOpenFailureText(Object error) {
  if (error is SiteAdapterError) return error.message;
  return '这一集没能打开，请回到选集重试';
}
