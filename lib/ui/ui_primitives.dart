import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'glass_surface.dart';

enum SiteLensNoticeTone { info, warning, error }

class SiteLensFoldable extends StatelessWidget {
  const SiteLensFoldable({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foldTheme = theme.expansionTileTheme.copyWith(
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(side: BorderSide.none),
      collapsedShape: const RoundedRectangleBorder(side: BorderSide.none),
      clipBehavior: Clip.none,
    );
    return Theme(
      data: theme.copyWith(expansionTileTheme: foldTheme),
      child: Material(
        type: MaterialType.transparency,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: child,
      ),
    );
  }
}

/// Shared page shell for secondary screens that use the standard app bar.
/// The home shell owns its navigation bar separately.
class SiteLensPageScaffold extends StatelessWidget {
  const SiteLensPageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), actions: actions),
    body: SafeArea(child: body),
  );
}

class SiteLensSectionHeader extends StatelessWidget {
  const SiteLensSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, SiteLensMetrics.sectionGap, 6, 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        ?action,
      ],
    ),
  );
}

class SiteLensActionRow extends StatelessWidget {
  const SiteLensActionRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    child: ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class SiteLensStatusBadge extends StatelessWidget {
  const SiteLensStatusBadge({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: color, fontWeight: FontWeight.w700);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.fromBorderSide(
          BorderSide(color: color.withValues(alpha: 0.28)),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 15 : 16, color: color),
          if (!compact) ...[
            const SizedBox(width: 5),
            Text(label, style: textStyle),
          ],
        ],
      ),
    );
  }
}

class SiteLensNotice extends StatelessWidget {
  const SiteLensNotice({
    super.key,
    required this.text,
    this.tone = SiteLensNoticeTone.error,
    this.action,
    this.onDismiss,
  });

  final String text;
  final SiteLensNoticeTone tone;
  final Widget? action;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = SiteLensColors.of(context);
    final (color, icon) = switch (tone) {
      SiteLensNoticeTone.info => (
        Theme.of(context).colorScheme.primary,
        Icons.info_outline,
      ),
      SiteLensNoticeTone.warning => (colors.warning, Icons.warning_amber),
      SiteLensNoticeTone.error => (colors.danger, Icons.error_outline),
    };
    return SiteLensGlassSurface(
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
            ?action,
            if (onDismiss != null)
              IconButton(
                tooltip: '清除这条提示',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

/// Material's dialog semantics and route behavior with a liquid-glass body.
class SiteLensAlertDialog extends StatelessWidget {
  const SiteLensAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 24,
      vertical: 24,
    ),
  });

  final Widget? title;
  final Widget? content;
  final List<Widget> actions;
  final EdgeInsets insetPadding;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    insetPadding: insetPadding,
    child: SiteLensGlassSurface(
      radius: SiteLensMetrics.panelRadius + 4,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              DefaultTextStyle(
                style: Theme.of(context).textTheme.titleMedium!,
                child: title!,
              ),
            if (title != null && content != null) const SizedBox(height: 16),
            if (content != null)
              Flexible(
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.bodyMedium!,
                  child: content!,
                ),
              ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(spacing: 8, runSpacing: 4, children: actions),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
