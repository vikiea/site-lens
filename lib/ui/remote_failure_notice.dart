import 'package:flutter/material.dart';

import '../media/remote_playback_failure.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';

/// 远程播放失败的四类结局（T8）。
///
/// 它和「需要重新登录」的提示同一个位置：导航器之上、WebView 之上。区别在于
/// 这里不只说一句话——每一类结局带着自己的动作：
/// - 凭证失效 → 去登录（续期失败之后才出现这个动作）；
/// - 清单失效 → 重试（重取清单再开一次，预算用尽后按钮变成建议）；
/// - 分片失败 → 下载该集；
/// - 网络失败 → 既有的网络错误文案，没有额外动作。
///
/// 文案与动作都来自 [RemoteFailureNotice]，这一层不自己判定种类，也不自己记
/// 重试次数：远程失败从不静默，每一次重试都是用户看得见的这一步。
class SiteLensRemoteFailureNoticeLayer extends StatelessWidget {
  const SiteLensRemoteFailureNoticeLayer({
    super.key,
    required this.child,
    required this.notice,
    required this.onDismiss,
    this.onRetry,
    this.onSignIn,
    this.onDownload,
  });

  final Widget child;
  final RemoteFailureNotice? notice;
  final VoidCallback onDismiss;

  /// 清单失效之后的「重试」。
  final VoidCallback? onRetry;

  /// 凭证失效之后的「去登录」。
  final VoidCallback? onSignIn;

  /// 分片失败之后的「下载该集」。
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final current = notice;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (current != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              minimum: const EdgeInsets.fromLTRB(
                SiteLensMetrics.pagePadding,
                8,
                SiteLensMetrics.pagePadding,
                0,
              ),
              child: _RemoteFailureCard(
                notice: current,
                onDismiss: onDismiss,
                onRetry: onRetry,
                onSignIn: onSignIn,
                onDownload: onDownload,
              ),
            ),
          ),
      ],
    );
  }
}

class _RemoteFailureCard extends StatelessWidget {
  const _RemoteFailureCard({
    required this.notice,
    required this.onDismiss,
    required this.onRetry,
    required this.onDownload,
    this.onSignIn,
  });

  final RemoteFailureNotice notice;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;
  final VoidCallback? onSignIn;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SiteLensColors.of(context);
    final action = _action(
      notice: notice,
      onRetry: onRetry,
      onSignIn: onSignIn,
      onDownload: onDownload,
    );
    return Semantics(
      container: true,
      liveRegion: true,
      label: notice.message,
      child: SiteLensGlassSurface(
        role: SiteLensSurfaceRole.platformView,
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_iconOf(notice.kind), size: 20, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    notice.message,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Semantics(
                  button: true,
                  label: '关闭远程播放失败提示',
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
              ],
            ),
            if (action != null)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    onDismiss();
                    action.run();
                  },
                  child: Text(action.label),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _iconOf(RemoteFailureKind kind) => switch (kind) {
    RemoteFailureKind.credentialRejected => Icons.key_off_outlined,
    RemoteFailureKind.manifestUnavailable => Icons.link_off,
    RemoteFailureKind.segmentFailed => Icons.download_for_offline_outlined,
    RemoteFailureKind.network => Icons.wifi_off_outlined,
  };

  /// 这一类的下一步。预算已经用完时，「重试」退化成建议文案里的那一句，按钮
  /// 不再出现——不留给用户一个点了也没用的重试。
  static ({String label, void Function() run})? _action({
    required RemoteFailureNotice notice,
    required VoidCallback? onRetry,
    required VoidCallback? onSignIn,
    required VoidCallback? onDownload,
  }) {
    switch (notice.action) {
      case RemoteFailureAction.refreshCredentialAndReopen:
        final signIn = onSignIn;
        if (signIn == null) return null;
        return (label: '去登录', run: signIn);
      case RemoteFailureAction.reloadManifestAndReopen:
        final retry = onRetry;
        // 自动重试用完之前重开由链自己执行；这里的手动重试只在这一类耗尽之后
        // 出现，用户自己再点一次重取清单——按钮就是「不静默」的那一半。
        if (retry == null || !notice.exhausted) return null;
        return (label: '重试', run: retry);
      case RemoteFailureAction.suggestDownload:
        final download = onDownload;
        if (download == null) return null;
        return (label: '下载该集', run: download);
      case RemoteFailureAction.keepNetworkMessage:
        // 网络失败沿用既有文案，没有额外的动作按钮。
        return null;
    }
  }
}
