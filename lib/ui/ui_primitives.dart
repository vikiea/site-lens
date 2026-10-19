import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'glass_surface.dart';

enum SiteLensNoticeTone { info, warning, error }

/// Keeps an episode suffix visible by trimming the left side when space is tight.
class SiteLensLeadingEllipsisText extends StatelessWidget {
  const SiteLensLeadingEllipsisText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final effective = DefaultTextStyle.of(context).style.merge(style);
      final direction = Directionality.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      bool fits(String value) {
        final painter = TextPainter(
          text: TextSpan(text: value, style: effective),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final result = painter.width <= constraints.maxWidth;
        painter.dispose();
        return result;
      }

      var display = text;
      if (constraints.hasBoundedWidth && !fits(text)) {
        final codeUnits = text.runes.toList();
        var low = 0;
        var high = codeUnits.length;
        while (low < high) {
          final middle = (low + high + 1) ~/ 2;
          final candidate =
              '…${String.fromCharCodes(codeUnits.skip(codeUnits.length - middle))}';
          if (fits(candidate)) {
            low = middle;
          } else {
            high = middle - 1;
          }
        }
        display =
            '…${String.fromCharCodes(codeUnits.skip(codeUnits.length - low))}';
      }
      return Text(
        display,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        semanticsLabel: text,
      );
    },
  );
}

class SiteLensFoldable extends StatefulWidget {
  const SiteLensFoldable({super.key, required this.child});

  final Widget child;

  @override
  State<SiteLensFoldable> createState() => _SiteLensFoldableState();
}

class _SiteLensFoldableState extends State<SiteLensFoldable> {
  bool _focused = false;

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
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (value) => setState(() => _focused = value),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
            side: BorderSide(
              color:
                  _focused &&
                      FocusManager.instance.highlightMode ==
                          FocusHighlightMode.traditional
                  ? theme.colorScheme.primary
                  : Colors.transparent,
            ),
          ),
        ),
        child: Theme(
          data: theme.copyWith(
            expansionTileTheme: foldTheme,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            highlightColor: Colors.transparent,
            splashColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
          ),
          child: Material(
            type: MaterialType.transparency,
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            child: widget.child,
          ),
        ),
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
    appBar: AppBar(actions: actions),
    body: Semantics(
      namesRoute: true,
      label: title,
      child: SafeArea(child: body),
    ),
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
