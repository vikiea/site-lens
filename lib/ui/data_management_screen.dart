import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../backup/backup_service.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'ui_util.dart';
import 'ui_primitives.dart';

class DataManagementScreen extends StatefulWidget {
  const DataManagementScreen({super.key, required this.app});
  final AppController app;
  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  bool busy = false;
  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    await safely(context, action);
    if (mounted) setState(() => busy = false);
  }

  Future<void> _export() async {
    final data = await widget.app.exportBackup();
    final result = await FilePicker.saveFile(
      bytes: data,
      fileName:
          'site-lens-${DateTime.now().toUtc().toIso8601String().substring(0, 10)}.backup.zip',
      mimeType: 'application/zip',
      dialogTitle: '保存完整备份',
    );
    if (result != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('完整备份已保存')));
    }
  }

  Future<void> _restore() async {
    final selected = await FilePicker.pickFiles(type: FileType.any);
    if (selected.isEmpty) return;
    final size = await selected.single.length();
    if (size == null || size > BackupService.maxBytes) {
      throw const FormatException('备份超过 64 MB 限制');
    }
    final snapshot = await widget.app.inspectBackup(
      await selected.single.readAsBytes(),
    );
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => SiteLensAlertDialog(
        title: const Text('替换本机业务数据？'),
        content: Text(
          '备份时间：${snapshot.createdAt}\n${snapshot.profiles} 个档案，${snapshot.scripts} 个脚本。\n\n恢复前会保留当前数据的安全备份；所有导入脚本关闭，确认权限后再启用。网页登录不会迁移。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复备份'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.app.restoreBackup(snapshot);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('业务数据已恢复，脚本需要重新确认；恢复前备份已保留在本机')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => SiteLensPageScaffold(
    title: '数据管理',
    body: ListView(
      padding: const EdgeInsets.fromLTRB(
        SiteLensMetrics.pagePadding,
        12,
        SiteLensMetrics.pagePadding,
        32,
      ),
      children: [
        Text('把档案、脚本与偏好带到新设备', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        Text(
          '完整备份包含发布页、候选站点、检测记录、脚本及其值与资源、设置和标签列表。Cookie、网页缓存及网站存储不在备份内。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: SiteLensMetrics.sectionGap),
        SiteLensPanel(
          padding: EdgeInsets.zero,
          child: SiteLensActionRow(
            icon: Icons.backup_outlined,
            title: '导出完整备份',
            subtitle: '保存为 .backup.zip 文件',
            onTap: busy ? null : () => _run(_export),
          ),
        ),
        const SizedBox(height: SiteLensMetrics.itemGap),
        SiteLensPanel(
          padding: EdgeInsets.zero,
          child: SiteLensActionRow(
            icon: Icons.restore,
            title: '恢复完整备份',
            subtitle: '校验后替换，并保留恢复前的数据',
            onTap: busy ? null : () => _run(_restore),
          ),
        ),
        const SizedBox(height: SiteLensMetrics.itemGap),
        SiteLensPanel(
          padding: EdgeInsets.zero,
          child: SiteLensActionRow(
            icon: Icons.settings_backup_restore,
            title: '恢复默认偏好',
            subtitle: '保留档案、脚本、脚本停用状态及浏览记录',
            onTap: busy ? null : () => _run(widget.app.resetPreferences),
          ),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(24),
            child: LinearProgressIndicator(),
          ),
        const SizedBox(height: SiteLensMetrics.sectionGap),
        Text(
          '备份文件可能包含脚本保存的私密值，请选择自己信任的保存位置。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}
