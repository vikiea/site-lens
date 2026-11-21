import 'media_service.dart';
import 'site_credential_handoff.dart';

/// 一次自动重开的下场。三种结局各有去处，不合并成一句「播放失败」。
enum ReopenStatus {
  /// 可以重开：调用方拿着 [CredentialReopenAttempt.reopen] 把本集再打开一次。
  scheduled,

  /// 这一段播放会话的重开预算已经用完：不再自动重开，也不再续期。
  exhausted,

  /// 站点在重推之后仍然拒绝：用户看到的是「需要重新登录」。
  needsLogin,
}

/// 一次「自动重开本集」的判定结果。
class CredentialReopenAttempt {
  const CredentialReopenAttempt({required this.status, this.reopen});

  final ReopenStatus status;

  /// 真正重开本集的动作；只有 [ReopenStatus.scheduled] 时非空。
  final void Function()? reopen;

  bool get scheduled => status == ReopenStatus.scheduled;
}

/// 凭证续期成功后**自动重开本集**的判定（T6）。
///
/// 续期与重推由 [SiteCredentialHandoff] 负责；它成功之后原生会自己对那一段会话
/// 重试一次。但原生那一份镜像与会话状态不保证能撑过换凭证这一下（换凭证往往
/// 意味着重新拉清单），所以应用侧要能**把当前这一集重新打开一次**：用户看到的
/// 是一次短暂停顿，不是错误页。
///
/// 有界且可去重：
/// - 一段播放会话只重开一次，按原生给出的 `sessionId` 计。重复到达的失效事件
///   不会再开一次播放器。
/// - 终止性拒绝（原生已经重试过、仍然被拒）直接落到「需要重新登录」，不重开。
/// - 重开动作不存在时是 [ReopenStatus.exhausted]，而不是静默重试。
///
/// 这里不缓存凭证、不读凭证：它只回答「这一次要不要重开、重开哪一段」。
class CredentialReopenPlanner {
  /// 每一段会话已经重开过的次数。会话结束后由 [forget] 释放，避免长会话里
  /// 无限增长。
  final _reopens = <String, int>{};

  /// 这段会话一共重开过几次。测试与诊断用，不涉及任何凭证值。
  int reopensFor(String sessionId) => _reopens[sessionId] ?? 0;

  /// 一段会话就此结束：它的预算可以回收。
  void forget(String sessionId) => _reopens.remove(sessionId);

  /// 一次失效事件之后要不要重开、重开用的是哪个动作。
  ///
  /// [reopen] 是调用方提供的「再开一次本集」；为 null 表示这次没法重开（页面
  /// 已经关了、候选已经不在了），结论是 [ReopenStatus.exhausted]。
  CredentialReopenAttempt plan({
    required NativeCredentialEvent event,
    required void Function()? reopen,
  }) {
    if (event.terminal) {
      // 站点在拿到新凭证之后仍然拒绝：再开一次只是把同一份拒绝再演一遍。
      return const CredentialReopenAttempt(status: ReopenStatus.needsLogin);
    }
    final used = _reopens[event.sessionId] ?? 0;
    if (used > 0) {
      // 同一段会话已经重开过：这一次不再叠加，也不再续期。
      return const CredentialReopenAttempt(status: ReopenStatus.exhausted);
    }
    if (reopen == null) {
      return const CredentialReopenAttempt(status: ReopenStatus.exhausted);
    }
    _reopens[event.sessionId] = used + 1;
    return CredentialReopenAttempt(
      status: ReopenStatus.scheduled,
      reopen: reopen,
    );
  }

  /// 从原生会话快照里取失效事件；不是凭证失效就是 null。
  ///
  /// 只有 `credentialRejected` 那一段错误码算数：网络失败、内容不可用各有自己
  /// 的文案，把它们也当成凭证失效会让用户在网络不好时被要求重新登录。
  static NativeCredentialEvent? eventIn(NativePlaybackSession session) =>
      NativeCredentialEvent.fromSession(session);
}
