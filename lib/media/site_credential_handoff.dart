import 'dart:async';

import '../domain/site_adapter.dart';
import '../domain/models.dart';
import '../media/native_credential_push.dart';
import '../site_credentials/site_credential_store.dart';
import '../media/native_media_runtime.dart';
import '../media/media_service.dart';

/// 一次失效事件（原生 → 应用）。它只说「哪一段会话、哪个档案、第几次」，
/// 不带任何凭证值。
class NativeCredentialEvent {
  const NativeCredentialEvent({
    required this.profileId,
    required this.sessionId,
    required this.attempt,
    required this.terminal,
  });

  /// 原生会话快照里 `errorCode` 的这一段前缀表示凭证失效；其余错误码仍然
  /// 是网络失败或内容不可用（GLOSSARY: 凭证失效）。
  static const rejectedPrefix = 'credentialRejected';

  final int profileId;
  final String sessionId;
  final int attempt;

  /// 这段会话已经用完了重试预算：应用不会再等原生重试。
  final bool terminal;

  /// 从原生会话快照里解析失效事件；不是失效就返回 null。
  static NativeCredentialEvent? fromSession(NativePlaybackSession session) {
    final code = session.errorCode;
    if (code == null || !code.startsWith(rejectedPrefix)) return null;
    final fields = <String, String>{};
    for (final part in code.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      fields[part.substring(0, separator).trim()] = part
          .substring(separator + 1)
          .trim();
    }
    return NativeCredentialEvent(
      profileId: int.tryParse(fields['profile'] ?? '') ?? -1,
      sessionId: session.id,
      attempt: int.tryParse(fields['attempt'] ?? '') ?? 1,
      terminal: fields['terminal'] == 'true',
    );
  }
}

/// 续期与重推的结果。每一种结局都有自己的去处：成功是「原生可以重试一次」，
/// 失败是「需要重新登录」，两者不合并成同一条文案（ADR-0007 Consequences）。
sealed class CredentialRecovery {
  const CredentialRecovery();
}

class CredentialRecovered extends CredentialRecovery {
  const CredentialRecovered({required this.credential, required this.pushed});

  final SiteCredential credential;

  /// 重推是否被原生接受。被拒绝时原生手里的还是上一份，重新登录仍然最稳妥。
  final bool pushed;
}

/// 续期失败：用户要看到的是「需要重新登录」，不是含糊的播放失败。
class CredentialNeedsLogin extends CredentialRecovery {
  const CredentialNeedsLogin();
}

/// 交接给应用侧的失效处置（T4）：
///
/// 1. 原生回传「凭证失效」→ 应用调用一次 [SiteAdapter.refreshCredential]；
/// 2. 续期成功 → 把新凭证推给原生，原生只重试一次；
/// 3. 续期失败或重推被拒 → [CredentialNeedsLogin]，提示出现在用户看得到的地方。
///
/// 同一段会话只续期一次：重复的失效事件不叠加请求，也不产生第二次重推。
class SiteCredentialHandoff {
  // 调用方只看到「适配器、推送、存储」三个必备项；字段随构造参数一起进来。
  SiteCredentialHandoff({
    required this.adapterRegistry,
    required this.pusher,
    required this.credentialSink,
    this.media,
    this.settleWindow = const Duration(milliseconds: 40),
  });

  final SiteAdapterRegistry adapterRegistry;
  final NativeCredentialPush pusher;
  final SiteCredentialSink credentialSink;
  final NativeMediaRuntime? media;
  final Duration settleWindow;
  final _recoveries = StreamController<CredentialRecovery>.broadcast();
  final _inFlight = <String>{};
  StreamSubscription<NativePlaybackSession>? _subscription;

  /// 每一次续期的结局，按发生顺序。
  Stream<CredentialRecovery> get recoveries => _recoveries.stream;

  /// 开始监听原生会话里的失效事件。
  void attach() {
    _subscription ??= media?.states.listen((session) {
      final event = NativeCredentialEvent.fromSession(session);
      if (event != null) unawaited(handle(event));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _recoveries.close();
  }

  /// 处置一次失效事件。
  Future<CredentialRecovery> handle(NativeCredentialEvent event) async {
    // 终止性拒绝（原生已经重试过、仍然被拒）不再续期：上一份凭证就是最终
    // 结论，直接落到「需要重新登录」。续期只会把一个已经确定的结局再拖一轮。
    if (event.terminal) return _needsLogin();
    // 同一段会话只续期一次：原生只重试一次，应用也只为它续期一次。
    if (!_inFlight.add(event.sessionId)) {
      return const CredentialNeedsLogin();
    }
    try {
      final resolution = await adapterRegistry.byProfile(
        SiteProfile(
          id: event.profileId,
          name: '',
          createdAt: DateTime.utc(2020),
        ),
      );
      final adapter = resolution.adapterOrNull;
      if (adapter == null) {
        // 没有适配器就没人能续期：这是一次「需要重新登录」，不是播放失败。
        return _needsLogin();
      }
      final cancel = CancellationSignal();
      final SiteCredential credential;
      try {
        credential = await adapter.refreshCredential(cancel);
      } on Object {
        // 续期失败（过期、被站点拒绝、没有刷新令牌）：落到重新登录。
        return _needsLogin();
      }
      if (!credential.isUsable) return _needsLogin();
      try {
        await credentialSink.saveCredential(adapter.profileId, credential);
      } on Object {
        return _needsLogin();
      }
      final bool pushed;
      try {
        final receipt = await pusher.push(
          adapter.profileId,
          credential,
          station: _stationOf(adapter),
        );
        pushed = receipt.accepted;
      } on Object {
        // 推送被拒（记录无法识别、桥接不在）也要落到重新登录：原生手里还是
        // 上一份，继续播放只会再收一次 401/403。
        return _needsLogin();
      }
      if (!pushed) return _needsLogin();
      // 原生收到新凭证后会自己对这一段会话重试一次；应用在这里只等它落定，
      // 不发起第二次续期。
      await _letNativeRetry();
      return _recover(
        recovered: CredentialRecovered(credential: credential, pushed: true),
      );
    } finally {
      _inFlight.remove(event.sessionId);
    }
  }

  CredentialNeedsLogin _needsLogin() =>
      _recover(recovered: const CredentialNeedsLogin());

  T _recover<T extends CredentialRecovery>({required T recovered}) {
    if (!_recoveries.isClosed) _recoveries.add(recovered);
    return recovered;
  }

  Future<void> _letNativeRetry() async {
    final media = this.media;
    if (media == null) return;
    try {
      await media.state().timeout(settleWindow);
    } on Object {
      // 会话已经结束或桥接已重绑定：原生那边不会再有第二次重试。
    }
  }

  Uri? _stationOf(SiteAdapter adapter) {
    final addresses = adapter.addresses;
    return addresses.isEmpty ? null : addresses.first;
  }
}

/// 应用侧保存凭证的入口。测试里用替身；正式代码里就是 [StoreCredentialSink]。
abstract interface class SiteCredentialSink {
  Future<void> saveCredential(int profileId, SiteCredential credential);
}

/// [SiteCredentialStore] 作为应用侧保存入口。存储本身没有第二个写路径：这里只是
/// 把它已有的 `save` 接到交接链需要的签名上。
class StoreCredentialSink implements SiteCredentialSink {
  const StoreCredentialSink(this.store);

  final SiteCredentialStore store;

  @override
  Future<void> saveCredential(int profileId, SiteCredential credential) =>
      store.save(profileId, credential);
}
