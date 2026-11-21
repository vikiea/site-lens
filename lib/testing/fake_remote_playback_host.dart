import 'dart:async';

import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/remote_playback_controller.dart';
import 'package:site_lens/media/remote_playback_failure.dart';

/// 播放页的假宿主：一个内存里的原生会话，没有通道、没有网络。
///
/// 它只做三件事：把 `openRemote` 记成一段新会话、把命令的结果推回
/// [nativeStates]、把失败交给真实的重试链判定。测试因此能在纯 widget 环境里
/// 走完「点开就播 → 跳集 → 连播 → 失败归因」的全流程。
class FakeRemotePlaybackHost implements RemotePlaybackHost {
  final controller = StreamController<NativePlaybackSession>.broadcast();

  /// 每一次 `openRemote` 收到的候选，按顺序。
  final opened = <MediaCandidate>[];

  /// 与 [opened] 一一对应的档案 id：换集与失败重开都必须带着它。
  final openedProfileIds = <int?>[];

  /// 每一次命令，形如 `seek:1500`、`speed:2.0`。
  final commands = <String>[];

  final closed = <String>[];

  /// 失败归因链就是生产里的那一条，不放宽预算。
  final retryChain = RemoteFailureRetryChain();
  final dismissed = <int>[];

  /// 下一次 open 之后原生会话的快照（视频尺寸、时长）。
  int videoWidth = 1920;
  int videoHeight = 1080;
  int durationMs = 600000;

  NativePlaybackSession? _active;
  NativePlaybackSession? get active => _active;
  int _opens = 0;

  Stream<NativePlaybackSession> get states => controller.stream;

  @override
  Stream<NativePlaybackSession> get nativeStates => controller.stream;

  @override
  Future<NativePlaybackSession> openRemote(
    MediaCandidate candidate, {
    int? profileId,
  }) async {
    _opens++;
    opened.add(candidate);
    openedProfileIds.add(profileId);
    final session = NativePlaybackSession(
      id: 'native_$_opens',
      candidateId: candidate.id,
      state: NativePlaybackState.playing,
      textureId: 7,
      durationMs: durationMs,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
    );
    _active = session;
    controller.add(session);
    return session;
  }

  @override
  Future<NativePlaybackSession> play(String sessionId) async {
    commands.add('play:$sessionId');
    return _update(NativePlaybackState.playing);
  }

  @override
  Future<NativePlaybackSession> pause(String sessionId) async {
    commands.add('pause:$sessionId');
    return _update(NativePlaybackState.paused);
  }

  @override
  Future<NativePlaybackSession> seek(
    Duration position,
    String sessionId,
  ) async {
    commands.add('seek:${position.inMilliseconds}');
    return _update(
      NativePlaybackState.playing,
      positionMs: position.inMilliseconds,
    );
  }

  @override
  Future<NativePlaybackSession> setSpeed(double speed, String sessionId) async {
    commands.add('speed:${speed.toStringAsFixed(2)}');
    return _update(NativePlaybackState.playing, speed: speed);
  }

  @override
  Future<NativePlaybackSession> close(String sessionId) async {
    closed.add(sessionId);
    // 换集时先开新会话再关旧的：关旧会话不能把新会话也从「当前」里抹掉。
    if (_active?.id == sessionId) _active = null;
    return NativePlaybackSession(
      id: sessionId,
      candidateId: '',
      state: NativePlaybackState.stopped,
    );
  }

  @override
  RemoteFailurePlan? observeRemoteFailure(
    NativePlaybackSession session, {
    void Function()? retry,
  }) {
    final failure = RemotePlaybackFailure.classify(session);
    if (failure == null) return null;
    final plan = retryChain.plan(failure: failure, retry: retry);
    if (plan.retries) plan.retry!();
    return plan;
  }

  @override
  void dismissRemoteFailure() {
    dismissed.add(_opens);
  }

  /// 让当前会话进入某个状态，模拟原生自己推上来的快照。
  void emit(
    NativePlaybackState state, {
    int positionMs = 0,
    String? errorCode,
  }) {
    final current = _active;
    if (current == null) return;
    _active = state == NativePlaybackState.stopped
        ? null
        : current.copyWith(
            state: state,
            positionMs: positionMs,
            errorCode: errorCode,
          );
    controller.add(_active ?? current);
  }

  /// 播放到结尾：原生会推一条 completed。
  void complete() {
    final current = _active;
    if (current == null) return;
    _active = current.copyWith(
      state: NativePlaybackState.completed,
      positionMs: durationMs,
    );
    controller.add(_active!);
  }

  NativePlaybackSession _update(
    NativePlaybackState state, {
    int? positionMs,
    double? speed,
  }) {
    final current = _active;
    if (current == null) {
      return const NativePlaybackSession(
        id: '',
        candidateId: '',
        state: NativePlaybackState.stopped,
      );
    }
    _active = current.copyWith(
      state: state,
      positionMs: positionMs ?? current.positionMs,
      speed: speed ?? current.speed,
    );
    controller.add(_active!);
    return _active!;
  }

  Future<void> dispose() async {
    await controller.close();
  }
}
