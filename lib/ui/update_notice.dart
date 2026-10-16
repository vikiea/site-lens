import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../update/update_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'navigation_observer.dart';
import 'software_update_screen.dart';

/// The in-app update notice: one glass capsule that slides in from the top of
/// whatever page the user is on — including above the native WebView — with
/// quick actions for opening the update page or handing the APK to the
/// installer. Swiping it away dismisses it for good.
class SiteLensUpdateNoticeLayer extends ConsumerWidget {
  const SiteLensUpdateNoticeLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(updateControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Stack(
        // Keep the navigator's tight constraints instead of loosening them.
        fit: StackFit.expand,
        children: [
          child,
          if (controller.noticeVisible)
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
                child: _UpdateNoticeCard(controller: controller),
              ),
            ),
        ],
      ),
    );
  }
}

class _UpdateNoticeCard extends StatefulWidget {
  const _UpdateNoticeCard({required this.controller});

  final UpdateController controller;

  @override
  State<_UpdateNoticeCard> createState() => _UpdateNoticeCardState();
}

class _UpdateNoticeCardState extends State<_UpdateNoticeCard>
    with SingleTickerProviderStateMixin {
  static const _visibleFor = Duration(seconds: 6);

  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..forward();
  Timer? _timer;
  String? _lastMessage;
  bool _timerSynced = false;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _UpdateNoticeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The old and new widgets share one controller, so the message is compared
    // against the value this card last saw instead of the previous widget.
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animation.dispose();
    super.dispose();
  }

  /// The install guidance must stay on screen until the user acts, so the
  /// auto-dismiss timer only runs while the card carries no guidance.
  void _syncTimer() {
    final message = widget.controller.installMessage;
    if (_timerSynced && message == _lastMessage) return;
    _timerSynced = true;
    _lastMessage = message;
    _timer?.cancel();
    _timer = null;
    if (message != null) return;
    _timer = Timer(_visibleFor, widget.controller.dismissNotice);
  }

  void _openUpdatePage() {
    final controller = widget.controller;
    final alreadyOpen = controller.updateScreenVisible;
    controller.dismissNotice();
    if (alreadyOpen) return;
    final navigator =
        siteLensNavigatorKey.currentState ?? Navigator.maybeOf(context);
    navigator?.push(
      MaterialPageRoute<void>(builder: (_) => const SoftwareUpdateScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final release = controller.release;
    final message = controller.installMessage;
    final theme = Theme.of(context);
    final colors = SiteLensColors.of(context);
    final title = release == null
        ? '更新包已下载完成'
        : 'Site Lens ${release.tagName} 已下载完成';
    final subtitle = message ?? '可以立即安装，或先查看更新详情';
    return Dismissible(
      key: const ValueKey('site-lens-update-notice'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => controller.dismissNotice(),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, -1.2), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic),
            ),
        child: FadeTransition(
          opacity: _animation,
          child: Semantics(
            container: true,
            liveRegion: true,
            excludeSemantics: true,
            label: '软件更新：$title。$subtitle',
            child: SiteLensGlassSurface(
              role: SiteLensSurfaceRole.platformView,
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        message == null
                            ? Icons.download_done_outlined
                            : Icons.warning_amber,
                        size: 20,
                        color: message == null
                            ? theme.colorScheme.primary
                            : colors.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.titleSmall,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              style: theme.textTheme.bodySmall,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // No Tooltip here: the notice renders above the
                      // navigator, so its subtree has no Overlay ancestor.
                      Semantics(
                        button: true,
                        excludeSemantics: true,
                        label: '不再提示这次更新',
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: controller.dismissNotice,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _openUpdatePage,
                        child: const Text('查看更新'),
                      ),
                      const SizedBox(width: 6),
                      FilledButton(
                        onPressed: controller.install,
                        child: const Text('安装'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
