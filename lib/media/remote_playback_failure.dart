/// 远程播放失败的四类归因与重试链（T8，ADR-0005）。
///
/// 远程播放可以不建任务，所以它的结局不能用 `MediaTaskState` 表达：这里给出
/// **远程特有**的失败种类与重试预算。它与本地播放失败（`MediaErrorCode` 下的
/// `reauthorize` / `network` / `cache_missing` …）不共用一套错误码，也不互相覆盖。
///
/// 四类结局各有各的去处（GLOSSARY: 凭证失效）：
/// - 凭证失效 → 续期后重开一次，续期失败才提示重新登录；
/// - 清单失效 → 重取清单后再开一次；
/// - 分片失败 → 报给用户并建议下载该集；
/// - 网络失败 → 沿用既有的网络错误文案。
///
/// 重试有界且可配，且从不静默：每一次重试都要在 [RemoteFailurePlan.retry] 里被
/// 调用方接住，耗尽后由 [RemoteFailureAction] 给出可行动的建议。
library;

import 'credential_reopen.dart';
import 'media_service.dart';
import 'site_credential_handoff.dart';

/// 远程播放失败的种类。四类互不混淆，判定见 [RemotePlaybackFailure.classify]。
enum RemoteFailureKind {
  /// 站点用 401/403 明确拒绝：凭证失效（GLOSSARY）。
  credentialRejected,

  /// 主清单取不到、或清单本身不可用：清单失效。
  manifestUnavailable,

  /// 清单尚可用，但某一个分片取不到：分片失败。
  segmentFailed,

  /// 连接、超时、DNS 之类的传输失败。
  network,
}

/// 四类结局各自的下一步。动作与文案一一对应，不合并成一句「播放失败」。
enum RemoteFailureAction {
  /// 续期凭证后重开本集；续期失败则提示重新登录。
  refreshCredentialAndReopen,

  /// 重取清单后再开一次。
  reloadManifestAndReopen,

  /// 建议用户下载该集（远程流的分片取不到，本地文件是更稳的路径）。
  suggestDownload,

  /// 沿用既有网络错误文案，不重开整集。
  keepNetworkMessage,
}

/// 远程失败在原生 → 应用边界上的错误码。
///
/// 凭证失效这一类仍然由既有的 [CredentialReopenPlanner] 判定「同会话只重开
/// 一次」；这里只给它一个种类与文案，不另起一套预算。
///
/// 与本地下载/播放的 `MediaErrorCode` 不共用任何一个常量：一份失败要么在这里
/// 被归到四类之一，要么根本不是远程归因。所有事件都以 [prefix] 开头；T4 的
/// `credentialRejected;` 凭证事件是四类里的一类。
class RemoteFailureCode {
  /// 一次远程失败事件的整体前缀。
  static const prefix = 'remoteFailure';

  /// 凭证失效（与 T4 的事件同名）。
  static const credentialRejected = NativeCredentialEvent.rejectedPrefix;

  /// 清单失效。
  static const manifestUnavailable = 'manifestUnavailable';

  /// 分片失败。
  static const segmentFailed = 'segmentFailed';

  /// 网络失败。
  static const network = 'remoteNetwork';

  /// 这条错误码是不是远程失败归因。
  static bool isRemote(String? code) =>
      (code ?? '').startsWith(prefix) ||
      (code ?? '').startsWith(NativeCredentialEvent.rejectedPrefix);
}

/// 一次远程失败的归因结果。
class RemotePlaybackFailure {
  const RemotePlaybackFailure({
    required this.kind,
    required this.sessionId,
    this.profileId,
    this.httpStatus,
    this.attempt = 1,
    this.exhausted = false,
  });

  final RemoteFailureKind kind;

  /// 发生失败的那一段原生会话。
  final String sessionId;

  /// 这条会话属于哪个站点档案；没有档案（公开内容）时为 null。
  final int? profileId;

  /// 能看到的 HTTP 状态；没有看到响应时为 null。
  final int? httpStatus;

  /// 这是这段会话里第几次同类远程失败（从 1 开始）。
  final int attempt;

  /// 重试预算已经用完：不再自动重试，直接给建议。
  final bool exhausted;

  RemotePlaybackFailure copyWith({int? attempt, bool? exhausted}) =>
      RemotePlaybackFailure(
        kind: kind,
        sessionId: sessionId,
        profileId: profileId,
        httpStatus: httpStatus,
        attempt: attempt ?? this.attempt,
        exhausted: exhausted ?? this.exhausted,
      );

  /// 从原生会话快照里判定这一次失败属于哪一类；不是失败就返回 null。
  ///
  /// 判定依据只有错误码：应用不认识的原生错误码一律落到网络失败，因为它是既有
  /// 文案里唯一一条「重试可能有用、不需要换凭证也不需要换清单」的建议。
  static RemotePlaybackFailure? classify(NativePlaybackSession session) {
    final raw = session.errorCode?.trim();
    if (raw == null || raw.isEmpty) return null;
    final fields = RemoteFailureFields.parse(raw);
    final kind = _kindOf(raw, fields);
    if (kind == null) return null;
    return RemotePlaybackFailure(
      kind: kind,
      // 预算按「这一集这一轮」记，不按会话 id：重开之后是新会话，若用 id
      // 作键，每次重开都会拿到一份新预算，重试就没有上限了。
      sessionId: session.candidateId.isEmpty ? session.id : session.candidateId,
      profileId: fields.profileId,
      httpStatus: fields.status,
      attempt: fields.attempt ?? 1,
      exhausted: fields.terminal,
    );
  }

  static RemoteFailureKind? _kindOf(String raw, RemoteFailureFields fields) {
    if (fields.credentialRejected) return RemoteFailureKind.credentialRejected;
    if (!raw.startsWith(RemoteFailureCode.prefix)) return null;
    switch (fields.kind) {
      case RemoteFailureCode.manifestUnavailable:
        return RemoteFailureKind.manifestUnavailable;
      case RemoteFailureCode.segmentFailed:
        return RemoteFailureKind.segmentFailed;
      case RemoteFailureCode.network:
        return RemoteFailureKind.network;
      case RemoteFailureCode.credentialRejected:
        return RemoteFailureKind.credentialRejected;
    }
    // 带远程前缀但种类不认识：按网络失败处置，不臆造成别的结论。
    return RemoteFailureKind.network;
  }

  /// 这一类的下一步（预算未耗尽时的第一选择）。
  RemoteFailureAction get action => switch (kind) {
    RemoteFailureKind.credentialRejected =>
      RemoteFailureAction.refreshCredentialAndReopen,
    RemoteFailureKind.manifestUnavailable =>
      RemoteFailureAction.reloadManifestAndReopen,
    RemoteFailureKind.segmentFailed => RemoteFailureAction.suggestDownload,
    RemoteFailureKind.network => RemoteFailureAction.keepNetworkMessage,
  };

  /// 这一类会不会**重开整集**。分片失败与网络失败不重开。
  bool get reopensEpisode =>
      kind == RemoteFailureKind.credentialRejected ||
      kind == RemoteFailureKind.manifestUnavailable;

  /// 用户看得到的那句话。四类各不相同，耗尽后的建议也不一样。
  String get message => switch (kind) {
    RemoteFailureKind.credentialRejected => '登录已失效，请重新登录后继续播放',
    RemoteFailureKind.manifestUnavailable => '这一集的地址已经失效，请回到选集重试',
    RemoteFailureKind.segmentFailed => '这一集有片段无法加载，可以下载该集后观看',
    RemoteFailureKind.network => '网络已切换，正在重新建立媒体连接；可重试',
  };
}

/// 远程播放特有的媒体源失败。
///
/// 原生数据源只回传两件事：哪一段地址坏了、这是清单还是分片。裸的传输失败
/// （超时、连接断开）在运行期没有这类事件，所以这里只有三种。
enum RemoteSourceFailure {
  /// 主清单取不到：清单失效。
  manifest,

  /// 清单里的某一个分片取不到：分片失败。
  segment,

  /// 站点明确拒绝这一条请求（401/403）：凭证失效，不算进分片失败的重试链。
  credentialRejected,
}

/// 原生一次播放错误归到哪一类远程结局。
///
/// [recoverable] 是原生自己判定的「传输层抖动」：它已经用自己的预算重试过一次
/// 仍失败时，用户的结论就是网络失败。[sourceFailure] 来自数据源，[httpStatus]
/// 是能看到的响应状态；两者都为空时只剩下 [recoverable] 这一条线索。
///
/// 这个函数与本地播放失败判定完全分开：它不接受任何 `MediaErrorCode`，也不返回
/// 任何本地错误码。
RemoteFailureKind remoteFailureKindFor({
  required bool recoverable,
  RemoteSourceFailure? sourceFailure,
  int? httpStatus,
}) {
  if (httpStatus != null) {
    final rejected = httpStatus == 401 || httpStatus == 403;
    if (rejected) return RemoteFailureKind.credentialRejected;
    // 其它 4xx 不是凭证问题：坏的是那一段地址，不是会话。
    if (httpStatus >= 400 && httpStatus < 500) {
      return switch (sourceFailure) {
        RemoteSourceFailure.manifest => RemoteFailureKind.manifestUnavailable,
        _ => RemoteFailureKind.segmentFailed,
      };
    }
  }
  return switch (sourceFailure) {
    RemoteSourceFailure.credentialRejected =>
      RemoteFailureKind.credentialRejected,
    RemoteSourceFailure.manifest => RemoteFailureKind.manifestUnavailable,
    RemoteSourceFailure.segment => RemoteFailureKind.segmentFailed,
    null => RemoteFailureKind.network,
  };
}

/// 一段远程失败错误码里的字段。原生只回传身份与次数，不回传任何凭证值。
class RemoteFailureFields {
  const RemoteFailureFields({
    required this.kind,
    required this.credentialRejected,
    this.status,
    this.profileId,
    this.attempt,
    this.terminal = false,
  });

  final String? kind;
  final bool credentialRejected;
  final int? status;
  final int? profileId;
  final int? attempt;
  final bool terminal;

  /// 解析 `kind=a;status=401;attempt=1;terminal=false` 这种形状。
  ///
  /// 第一个 token 是事件名（`remoteFailure` 或 `credentialRejected`），也是判定
  /// 凭证失效的那一段，所以它不要求写成 `kind=`。
  static RemoteFailureFields parse(String raw) {
    final fields = <String, String>{};
    var event = '';
    for (final part in raw.split(';')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf('=');
      if (separator <= 0) {
        if (event.isEmpty) event = trimmed;
        continue;
      }
      fields[trimmed.substring(0, separator).trim()] = trimmed
          .substring(separator + 1)
          .trim();
    }
    final kind = fields['kind'] ?? (event.isEmpty ? null : event);
    return RemoteFailureFields(
      kind: kind,
      credentialRejected:
          kind == NativeCredentialEvent.rejectedPrefix ||
          event == NativeCredentialEvent.rejectedPrefix,
      status: int.tryParse(fields['status'] ?? ''),
      profileId: int.tryParse(fields['profile'] ?? fields['profileId'] ?? ''),
      attempt: int.tryParse(fields['attempt'] ?? ''),
      terminal: fields['terminal'] == 'true',
    );
  }
}

/// 重试策略：次数与间隔都可配，且有上限。
///
/// 「重试有界」靠 [perSession] 这道硬上限：即使调用方把 [maxAttempts] 调大，
/// 同一段会话也不会超过 [perSession] 次自动重试。禁用时一切自动重试都变成
/// [RemoteFailurePlan.manual]——不静默，也不假装成功。
class RemoteRetryPolicy {
  const RemoteRetryPolicy({this.maxAttempts = 1, this.delay = Duration.zero})
    : assert(maxAttempts >= 0);

  /// 不自动重试：每一次失败都直接给建议。
  static const none = RemoteRetryPolicy(maxAttempts: 0);

  /// 每一类自动重试的硬上限。凭证失效与清单失效「各自只自动重试一次」就是它。
  static const perSession = 1;

  /// 配置想给这一类的自动重试上限；实际生效的是它和 [perSession] 的较小者。
  final int maxAttempts;

  /// 两次尝试之间的等待。为 [Duration.zero] 时立即执行，但仍然不是静默重试：
  /// 每一次都会经过 [RemoteFailurePlan.retry]。
  final Duration delay;

  /// 这一类实际生效的上限。
  int budgetFor(RemoteFailureKind kind) => switch (kind) {
    RemoteFailureKind.credentialRejected => maxAttempts.clamp(0, perSession),
    RemoteFailureKind.manifestUnavailable => maxAttempts.clamp(0, perSession),
    // 分片失败与网络失败不重开整集：它们的预算恒为 0。
    RemoteFailureKind.segmentFailed => 0,
    RemoteFailureKind.network => 0,
  };

  RemoteRetryPolicy copyWith({int? maxAttempts, Duration? delay}) =>
      RemoteRetryPolicy(
        maxAttempts: maxAttempts ?? this.maxAttempts,
        delay: delay ?? this.delay,
      );
}

/// 一次远程失败处置的结论：要么带着一个**显式**重试动作，要么只给建议。
class RemoteFailurePlan {
  const RemoteFailurePlan({
    required this.failure,
    required this.action,
    required this.message,
    this.retry,
    this.delay = Duration.zero,
  });

  final RemotePlaybackFailure failure;
  final RemoteFailureAction action;
  final String message;

  /// 这一次要执行的重试；为 null 表示不重试，只给建议。重试从不静默：调用方
  /// 显式执行它，或在界面上让用户点。
  final void Function()? retry;

  /// 执行 [retry] 之前等多久。
  final Duration delay;

  bool get retries => retry != null;
}

/// 四类远程失败的重试链。
///
/// 预算按「会话 + 种类」记：同一段会话的凭证失效与清单失效各有一次机会，互不
/// 占用；换一段会话（重开之后原生给的新会话）重新开始。一段会话结束时用
/// [forget] 回收，避免长会话里无限增长。
class RemoteFailureRetryChain {
  RemoteFailureRetryChain({this.policy = const RemoteRetryPolicy()});

  /// 次数与间隔可配；改它只影响之后的失败，已经记下的预算不清零。
  RemoteRetryPolicy policy;

  final _attempts = <String, int>{};

  /// 这一段会话的某一类已经自动重试过几次。测试与诊断用，不涉及任何凭证值。
  int attemptsFor(String sessionId, RemoteFailureKind kind) =>
      _attempts[_key(sessionId, kind)] ?? 0;

  /// 一段会话就此结束：它的预算可以回收。
  void forget(String sessionId) {
    for (final kind in RemoteFailureKind.values) {
      _attempts.remove(_key(sessionId, kind));
    }
  }

  /// 归因并给出下一步。
  ///
  /// [retry] 是「再开一次」的动作：凭证失效时是「续期后重开」，清单失效时是
  /// 「重取清单后再开」。为 null 表示调用方这次没法重开（候选已经不在了），
  /// 结论是直接给建议，而不是静默重试。
  ///
  /// 终止性失败（原生已经用完它自己的重试）不再自动重试，直接落到这一类耗尽后
  /// 的建议。
  RemoteFailurePlan plan({
    required RemotePlaybackFailure failure,
    void Function()? retry,
  }) {
    final action = failure.action;
    final budget = policy.budgetFor(failure.kind);
    final used = attemptsFor(failure.sessionId, failure.kind);
    if (failure.exhausted || retry == null || used >= budget) {
      return RemoteFailurePlan(
        failure: failure.copyWith(
          attempt: used + 1,
          exhausted: failure.exhausted || used >= budget,
        ),
        action: action,
        message: failure.message,
      );
    }
    _attempts[_key(failure.sessionId, failure.kind)] = used + 1;
    return RemoteFailurePlan(
      failure: failure.copyWith(attempt: used + 1),
      action: action,
      message: failure.message,
      retry: retry,
      delay: policy.delay,
    );
  }

  static String _key(String sessionId, RemoteFailureKind kind) =>
      '$sessionId\u0000${kind.name}';
}
