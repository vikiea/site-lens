import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'glass_surface.dart';

enum SiteLensNoticeTone { info, warning, error }

/// A bounded glass viewport: one material and one lazy page scroll owner.
/// Long lists must not size their glass layer to the full content extent.
class SiteLensListPanel extends StatelessWidget {
  const SiteLensListPanel({
    super.key,
    required this.slivers,
    this.controller,
    this.scrollKey,
  });

  final List<Widget> slivers;
  final ScrollController? controller;
  final Key? scrollKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(SiteLensMetrics.pagePadding),
    child: SiteLensPanel(
      padding: EdgeInsets.zero,
      child: CustomScrollView(
        key: scrollKey,
        controller: controller,
        slivers: slivers,
      ),
    ),
  );
}

class SiteLensPanelDivider extends StatelessWidget {
  const SiteLensPanelDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(
    height: 1,
    indent: SiteLensMetrics.compactDividerIndent,
    endIndent: SiteLensMetrics.compactDividerIndent,
  );
}

class SiteLensSettingsDivider extends StatelessWidget {
  const SiteLensSettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(
    height: 1,
    indent: SiteLensMetrics.settingsDividerIndent,
    endIndent: SiteLensMetrics.settingsDividerIndent,
  );
}

/// Compact visuals retain a complete row activation target and text scaling.
class SiteLensCompactRow extends StatelessWidget {
  const SiteLensCompactRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    minTileHeight: SiteLensMetrics.compactRowMinHeight,
    minLeadingWidth: SiteLensMetrics.compactIconSize,
    horizontalTitleGap: 8,
    minVerticalPadding: SiteLensMetrics.compactRowVerticalPadding,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: SiteLensMetrics.compactRowHorizontalPadding,
      vertical: SiteLensMetrics.compactRowVerticalPadding,
    ),
    leading: leading,
    title: title,
    subtitle: subtitle,
    trailing: trailing,
    onTap: onTap,
  );
}

/// A controlled disclosure; callers own one selected ID per semantic panel.
/// Details are built only when open, including in lazy lists.
class SiteLensDisclosure extends StatelessWidget {
  const SiteLensDisclosure({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.details,
    this.subtitle,
    this.leading,
    this.trailing,
    this.trailingBuilder,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget Function(BuildContext context, bool expanded)? trailingBuilder;
  final bool expanded;
  final VoidCallback onToggle;
  final WidgetBuilder details;

  @override
  Widget build(BuildContext context) => SiteLensFoldable(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: expanded,
          child: SiteLensCompactRow(
            title: title,
            subtitle: subtitle,
            leading: leading,
            trailing:
                trailingBuilder?.call(context, expanded) ??
                trailing ??
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: SiteLensMetrics.compactIconSize,
                ),
            onTap: onToggle,
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SiteLensMetrics.compactRowHorizontalPadding,
              0,
              SiteLensMetrics.compactRowHorizontalPadding,
              SiteLensMetrics.formGap,
            ),
            child: details(context),
          ),
      ],
    ),
  );
}

class SiteLensAccordionController extends ChangeNotifier {
  Object? _openId;

  Object? get openId => _openId;

  void toggle(Object id) {
    _openId = _openId == id ? null : id;
    notifyListeners();
  }

  void close(Object id) {
    if (_openId != id) return;
    _openId = null;
    notifyListeners();
  }
}

class SiteLensAccordion extends StatefulWidget {
  const SiteLensAccordion({
    super.key,
    required this.id,
    required this.controller,
    required this.title,
    required this.details,
    this.subtitle,
    this.leading,
    this.trailing,
    this.trailingBuilder,
    this.initiallyExpanded = false,
  });

  final Object id;
  final SiteLensAccordionController controller;
  final Widget title;
  final WidgetBuilder details;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget Function(BuildContext context, bool expanded)? trailingBuilder;
  final bool initiallyExpanded;

  @override
  State<SiteLensAccordion> createState() => _SiteLensAccordionState();
}

class _SiteLensAccordionState extends State<SiteLensAccordion> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    if (widget.initiallyExpanded && widget.controller.openId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.openId == null) {
          widget.controller.toggle(widget.id);
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant SiteLensAccordion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final expanded = widget.controller.openId == widget.id;
    return SiteLensDisclosure(
      title: widget.title,
      subtitle: widget.subtitle,
      leading: widget.leading,
      trailingBuilder: widget.trailingBuilder,
      trailing: widget.trailing,
      expanded: expanded,
      onToggle: () => widget.controller.toggle(widget.id),
      details: widget.details,
    );
  }
}

/// A titled settings group uses one glass boundary and keeps its controls
/// visible. Detail disclosure belongs to rows inside a group, not to the
/// category surface itself.
class SiteLensSettingsPanel extends StatelessWidget {
  const SiteLensSettingsPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => SiteLensPanel(
    padding: EdgeInsets.zero,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SiteLensCompactRow(
          leading: Icon(icon, size: SiteLensMetrics.compactIconSize),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle!),
        ),
        const Divider(
          height: 1,
          indent: SiteLensMetrics.settingsDividerIndent,
          endIndent: SiteLensMetrics.settingsDividerIndent,
        ),
        child,
      ],
    ),
  );
}

@immutable
class SiteLensMenuOption<T> {
  const SiteLensMenuOption({
    required this.value,
    required this.label,
    this.enabled = true,
  });

  final T value;
  final String label;
  final bool enabled;
}

/// A single-tap choice menu sized to its longest label, within parent bounds.
class SiteLensMenuSelector<T> extends StatefulWidget {
  const SiteLensMenuSelector({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final T value;
  final List<SiteLensMenuOption<T>> options;
  final ValueChanged<T>? onSelected;

  @override
  State<SiteLensMenuSelector<T>> createState() =>
      _SiteLensMenuSelectorState<T>();
}

class _SiteLensMenuSelectorState<T> extends State<SiteLensMenuSelector<T>> {
  final _focusNode = FocusNode();
  final _menuController = MenuController();
  bool _expanded = false;

  bool get _enabled =>
      widget.onSelected != null &&
      widget.options.any(
        (option) => option.enabled && option.value != widget.value,
      );

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_highlightModeChanged);
  }

  void _highlightModeChanged(FocusHighlightMode _) => setState(() {});

  @override
  void didUpdateWidget(covariant SiteLensMenuSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _menuController.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_enabled) _menuController.close();
      });
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_highlightModeChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    assert(
      widget.options.where((option) => option.value == widget.value).length ==
          1,
    );
    final selected = widget.options.firstWhere(
      (option) => option.value == widget.value,
    );
    final theme = Theme.of(context);
    final colors = SiteLensColors.of(context);
    final textStyle = theme.textTheme.bodySmall ?? const TextStyle();
    // Keep the menu close to the surrounding glass surface. A neutral fill
    // keeps the selector visually grouped with the gesture row instead of
    // making it read like a separate primary-colored control.
    final fill = colors.glassSurface.withValues(alpha: 1);
    final showFocusOutline =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    const horizontalPadding = SiteLensMetrics.formGap;
    const iconSize = SiteLensMetrics.navIconSize;
    const gap = SiteLensMetrics.itemGap;
    var labelWidth = 0.0;
    for (final option in widget.options) {
      final painter = TextPainter(
        text: TextSpan(text: option.label, style: textStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > labelWidth) labelWidth = painter.width;
      painter.dispose();
    }
    final preferredWidth =
        labelWidth.ceilToDouble() + horizontalPadding * 2 + iconSize + gap;
    final foreground = WidgetStateProperty.resolveWith<Color>(
      (states) => states.contains(WidgetState.disabled)
          ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
          : theme.colorScheme.onSurface,
    );
    final style = ButtonStyle(
      textStyle: WidgetStatePropertyAll(textStyle),
      foregroundColor: foreground,
      iconColor: foreground,
      iconSize: const WidgetStatePropertyAll(iconSize),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      animationDuration: Duration.zero,
      minimumSize: const WidgetStatePropertyAll(
        Size(0, kMinInteractiveDimension),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: gap),
      ),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      alignment: AlignmentDirectional.centerStart,
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
        ),
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color:
              showFocusOutline &&
                  states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.disabled)
              ? theme.colorScheme.primary
              : Colors.transparent,
          width: 1.4,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : preferredWidth;
        final width = math.min(preferredWidth, maxWidth);
        return SizedBox(
          width: width,
          child: MenuAnchor(
            controller: _menuController,
            childFocusNode: _focusNode,
            consumeOutsideTap: true,
            crossAxisUnconstrained: false,
            onOpen: () => setState(() => _expanded = true),
            onClose: () => setState(() => _expanded = false),
            style: MenuStyle(
              alignment: AlignmentDirectional.bottomStart,
              backgroundColor: WidgetStatePropertyAll(fill),
              elevation: const WidgetStatePropertyAll(0),
              shadowColor: const WidgetStatePropertyAll(Colors.transparent),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              minimumSize: WidgetStatePropertyAll(Size(width, 0)),
              maximumSize: WidgetStatePropertyAll(Size(width, double.infinity)),
              visualDensity: VisualDensity.standard,
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(SiteLensMetrics.inputRadius),
                  ),
                  side: BorderSide.none,
                ),
              ),
            ),
            menuChildren: [
              for (final option in widget.options)
                if (option.value != widget.value)
                  MenuItemButton(
                    style: style,
                    onPressed: !_enabled || !option.enabled
                        ? null
                        : () => widget.onSelected?.call(option.value),
                    child: Semantics(child: Text(option.label)),
                  ),
            ],
            builder: (context, controller, _) => Tooltip(
              message: widget.label,
              excludeFromSemantics: true,
              child: SizedBox(
                width: width,
                child: TextButton(
                  focusNode: _focusNode,
                  style: style.copyWith(
                    backgroundColor: WidgetStatePropertyAll(fill),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: const Radius.circular(
                            SiteLensMetrics.inputRadius,
                          ),
                          bottom: Radius.circular(
                            _expanded ? 0 : SiteLensMetrics.inputRadius,
                          ),
                        ),
                      ),
                    ),
                    side: WidgetStateProperty.resolveWith(
                      (states) => BorderSide(
                        color:
                            showFocusOutline &&
                                states.contains(WidgetState.focused) &&
                                _enabled
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        width: 1.4,
                      ),
                    ),
                  ),
                  onPressed: !_enabled
                      ? null
                      : () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                  child: Semantics(
                    label: widget.label,
                    value: selected.label,
                    expanded: _expanded,
                    excludeSemantics: true,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            selected.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: gap),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: iconSize,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

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
    appBar:
        ModalRoute.of(context)?.impliesAppBarDismissal == true ||
            actions?.isNotEmpty == true
        ? AppBar(actions: actions)
        : null,
    body: Semantics(
      namesRoute: true,
      label: title,
      child: SafeArea(child: body),
    ),
  );
}

/// Refresh action with continuous activity feedback and reduced-motion support.
class SiteLensRefreshButton extends StatefulWidget {
  const SiteLensRefreshButton({
    super.key,
    required this.tooltip,
    required this.refreshing,
    required this.onPressed,
  });

  final String tooltip;
  final bool refreshing;
  final VoidCallback? onPressed;

  @override
  State<SiteLensRefreshButton> createState() => _SiteLensRefreshButtonState();
}

class _SiteLensRefreshButtonState extends State<SiteLensRefreshButton>
    with SingleTickerProviderStateMixin {
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  void _syncAnimation() {
    if (widget.refreshing && !MediaQuery.disableAnimationsOf(context)) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
      _rotation.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant SiteLensRefreshButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.refreshing ? '${widget.tooltip}，刷新中' : widget.tooltip,
    onPressed: widget.refreshing ? null : widget.onPressed,
    icon: RotationTransition(
      turns: _rotation,
      child: Icon(
        Icons.refresh,
        color: widget.refreshing ? Theme.of(context).colorScheme.primary : null,
      ),
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
    padding: const EdgeInsets.fromLTRB(
      SiteLensMetrics.settingsSectionLabelHorizontalPadding,
      SiteLensMetrics.sectionGap,
      SiteLensMetrics.settingsSectionLabelHorizontalPadding,
      SiteLensMetrics.settingsSectionLabelBottom,
    ),
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

/// A persistent informational notice with one quiet, durable dismissal action.
/// The caller owns the setting so the same surface can be used by any screen.
class SiteLensPersistentNotice extends StatelessWidget {
  const SiteLensPersistentNotice({
    super.key,
    required this.dismissed,
    required this.text,
    required this.onDismiss,
  });

  final bool dismissed;
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (dismissed) return const SizedBox.shrink();
    final colors = SiteLensColors.of(context);
    return SiteLensNotice(
      tone: SiteLensNoticeTone.info,
      text: text,
      action: TextButton(
        onPressed: onDismiss,
        style: TextButton.styleFrom(
          foregroundColor: colors.sectionLabel,
          textStyle: Theme.of(context).textTheme.labelSmall,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('不再提示'),
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
