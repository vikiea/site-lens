import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'app_controller.dart';
import 'glass_surface.dart';
import 'ui_primitives.dart';
import 'ui_util.dart';

class ErrorLogsScreen extends StatefulWidget {
  const ErrorLogsScreen({super.key, required this.app});

  final AppController app;

  @override
  State<ErrorLogsScreen> createState() => _ErrorLogsScreenState();
}

class _ErrorLogsScreenState extends State<ErrorLogsScreen> {
  late Future<List<AppErrorLog>> _logs = widget.app.db.appErrorLogs();

  void _reload() {
    setState(() => _logs = widget.app.db.appErrorLogs());
  }

  Future<void> _clear() async {
    await widget.app.db.clearAppErrorLogs();
    if (mounted) {
      showShortToast(context, '日志已清空');
      _reload();
    }
  }

  Future<void> _showDetails(AppErrorLog log) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('错误详情', style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 12),
              _LogRow(label: '模块', value: log.module),
              _LogRow(label: '时间', value: clock(log.happenedAt)),
              _LogRow(label: '提示', value: log.message),
              _LogRow(label: '上下文', value: log.context ?? '无'),
              _LogRow(label: '诊断信息', value: log.details),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text:
                          '${log.happenedAt.toIso8601String()} · ${log.module}\n${log.message}\n${log.details}',
                    ),
                  );
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (mounted) showShortToast(context, '错误详情已复制');
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制详情'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SiteLensPageScaffold(
    title: '错误日志',
    actions: [
      IconButton(
        tooltip: '刷新',
        onPressed: _reload,
        icon: const Icon(Icons.refresh),
      ),
      IconButton(
        tooltip: '清空',
        onPressed: _clear,
        icon: const Icon(Icons.delete_sweep_outlined),
      ),
    ],
    body: FutureBuilder<List<AppErrorLog>>(
      future: _logs,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final logs = snapshot.data!;
        if (logs.isEmpty) {
          return const SiteLensEmptyState(
            icon: Icons.check_circle_outline,
            title: '暂无错误日志',
            message: '应用遇到异常时，会在这里保留经过脱敏的诊断记录。',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          itemCount: logs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final log = logs[index];
            return SiteLensPanel(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(
                  log.level == 'warning'
                      ? Icons.warning_amber_outlined
                      : Icons.error_outline,
                ),
                title: Text(
                  log.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${log.module} · ${clock(log.happenedAt)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showDetails(log),
              ),
            );
          },
        );
      },
    ),
  );
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 72, child: Text(label)),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
