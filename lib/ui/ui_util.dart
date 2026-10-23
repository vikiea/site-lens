import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../diagnostics/error_log.dart';
import '../network/transport.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';

String clock(DateTime? value) =>
    value == null ? '尚未刷新' : value.toLocal().toString().split('.').first;

String formatBytes(int bytes) {
  if (bytes < 0) return '未知大小';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value == value.roundToDouble() || value >= 100
      ? 0
      : value >= 10
      ? 1
      : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatMediaDuration(int milliseconds) {
  if (milliseconds <= 0) return '--:--';
  final totalSeconds = milliseconds ~/ 1000;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

void showShortToast(BuildContext context, String message) {
  if (!context.mounted) return;
  final screenWidth = MediaQuery.sizeOf(context).width;
  final estimatedWidth = 32 + message.runes.length * 14.0;
  final width = estimatedWidth.clamp(120.0, screenWidth - 32).toDouble();
  final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, maxLines: 1, overflow: TextOverflow.ellipsis),
      behavior: SnackBarBehavior.floating,
      width: width,
      duration: const Duration(seconds: 1),
    ),
  );
}

/// Long press any URL-like value to copy it without making the whole row
/// editable. The row can still keep its normal tap action around this child.
class SiteLensCopyableText extends StatelessWidget {
  const SiteLensCopyableText({
    super.key,
    required this.text,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: () async {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制链接'), duration: Duration(seconds: 1)),
      );
    },
    child: Text(text, style: style, maxLines: maxLines, overflow: overflow),
  );
}

String statusLabel(ProbeResult r) => switch (r.status) {
  ProbeStatus.reachable => '初筛可达 · 未验证',
  ProbeStatus.ready => '首页已就绪',
  ProbeStatus.unavailable => '不可用',
  ProbeStatus.timeout => '超时',
  ProbeStatus.offline => '网络失败',
  ProbeStatus.certificateError => '证书错误',
  ProbeStatus.challenge => '验证码',
  ProbeStatus.interactionRequired => '需要交互',
  ProbeStatus.unsupported => '能力不可用',
  ProbeStatus.cancelled => '已取消',
};

String healthLabel(ProfileHealthState state) => switch (state) {
  ProfileHealthState.unknown => '未检查',
  ProfileHealthState.ok => '可达',
  ProfileHealthState.failing => '连续不可达',
};

/// One empty state for the whole app: icon, one sentence, one action. Screens
/// used to each invent their own padding and type.
class SiteLensEmptyState extends StatelessWidget {
  const SiteLensEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(SiteLensMetrics.sectionGap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 36,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}

/// The app's one error surface: same panel, same icon, same dismiss affordance
/// wherever a failure is reported.
class SiteLensErrorBanner extends StatelessWidget {
  const SiteLensErrorBanner({
    super.key,
    required this.text,
    this.onDismiss,
    this.action,
  });
  final String text;
  final VoidCallback? onDismiss;
  final Widget? action;

  @override
  Widget build(BuildContext context) =>
      SiteLensNotice(text: text, action: action, onDismiss: onDismiss);
}

String friendlyError(Object error) {
  return readableError(error);
}

void showError(BuildContext context, Object error) {
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(friendlyError(error))));
  }
}

Future<void> safely(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    AppErrorLogger.capture(e, module: 'ui');
    if (context.mounted) showError(context, e);
  }
}

/// A one-field prompt whose [TextEditingController] is owned by the dialog.
///
/// Disposing the controller as soon as `showDialog` returns tears it out from
/// under the still-animating field ("A TextEditingController was used after
/// being disposed"), so every caller goes through this instead.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? initial,
  String? hintText,
  String? helperText,
  String confirmLabel = '保存',
  TextInputType? keyboardType,
  SiteLensSurfaceRole surfaceRole = SiteLensSurfaceRole.panel,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextPromptDialog(
    title: title,
    initial: initial,
    hintText: hintText,
    helperText: helperText,
    confirmLabel: confirmLabel,
    keyboardType: keyboardType,
    surfaceRole: surfaceRole,
  ),
);

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.confirmLabel,
    this.initial,
    this.hintText,
    this.helperText,
    this.keyboardType,
    required this.surfaceRole,
  });
  final String title;
  final String confirmLabel;
  final String? initial;
  final String? hintText;
  final String? helperText;
  final TextInputType? keyboardType;
  final SiteLensSurfaceRole surfaceRole;
  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final controller = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, controller.text.trim());

  @override
  Widget build(BuildContext context) => SiteLensAlertDialog(
    surfaceRole: widget.surfaceRole,
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      keyboardType: widget.keyboardType,
      decoration: InputDecoration(
        hintText: widget.hintText,
        helperText: widget.helperText,
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
    ],
  );
}
