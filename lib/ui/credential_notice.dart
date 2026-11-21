import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';

/// 「需要重新登录」的提示（T4）。
///
/// 它和更新提示同一个位置：导航器之上、WebView 之上，无论用户当时在剧场、选集
/// 还是播放页都能看到。凭证续期失败与网络失败是两种结局，这里的文案只说前者，
/// 不把它混进「播放失败」。
class SiteLensCredentialNoticeLayer extends ConsumerWidget {
  const SiteLensCredentialNoticeLayer({
    super.key,
    required this.child,
    this.onSignIn,
  });

  final Widget child;

  /// 用户点「去登录」。没有给定时按钮只负责关掉提示，由调用方接上登录容器。
  final void Function(int profileId)? onSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final message = app.credentialPromptText;
    return Stack(
      // 保持导航器的紧约束，不因为提示层而放宽。
      fit: StackFit.expand,
      children: [
        child,
        if (message != null)
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
              child: _CredentialNoticeCard(
                message: message,
                profileId: app.credentialNeedsLoginProfileId,
                onDismiss: app.dismissCredentialPrompt,
                onSignIn: onSignIn,
              ),
            ),
          ),
      ],
    );
  }
}

class _CredentialNoticeCard extends StatelessWidget {
  const _CredentialNoticeCard({
    required this.message,
    required this.profileId,
    required this.onDismiss,
    required this.onSignIn,
  });

  final String message;
  final int? profileId;
  final VoidCallback onDismiss;
  final void Function(int profileId)? onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SiteLensColors.of(context);
    final target = profileId;
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
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
                Icon(Icons.key_off_outlined, size: 20, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Semantics(
                  button: true,
                  label: '关闭重新登录提示',
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () {
                  onDismiss();
                  if (target != null) onSignIn?.call(target);
                },
                child: const Text('重新登录'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
