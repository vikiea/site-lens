import 'package:flutter/material.dart';

import '../media/media_organization.dart';
import 'app_theme.dart';
import 'ui_primitives.dart';

enum MediaBrowserAction { rename, move, copy, delete }

class MediaBrowserOperations {
  const MediaBrowserOperations({
    required this.renameItem,
    required this.moveItem,
    required this.copyItem,
    required this.deleteItem,
    required this.preflightDelete,
    required this.preflightCopy,
  });

  final Future<void> Function(String itemId, String name) renameItem;
  final Future<void> Function(String itemId, String? folderId) moveItem;
  final Future<String> Function(String itemId) copyItem;
  final Future<void> Function(String itemId) deleteItem;
  final Future<String?> Function(String itemId) preflightDelete;
  final Future<String?> Function(String itemId) preflightCopy;
}

class MediaBrowserController extends ChangeNotifier {
  MediaBrowserController({required this.organization});

  final MediaOrganizationService organization;
  String? folderId;
  bool selectionMode = false;
  bool busy = false;
  final selectedItemIds = <String>{};
  final selectedFolderIds = <String>{};

  List<MediaOrganizationFolder> get folders => organization.children(folderId);

  bool get atRoot => folderId == null;

  MediaOrganizationFolder? get currentFolder =>
      folderId == null ? null : organization.folder(folderId!);

  void openFolder(String id) {
    if (!organization.hasFolder(id)) return;
    folderId = id;
    clearSelection();
    notifyListeners();
  }

  void goUp() {
    final current = currentFolder;
    folderId = current?.parentId;
    clearSelection();
    notifyListeners();
  }

  void enterSelection() {
    selectionMode = true;
    notifyListeners();
  }

  void exitSelection() {
    selectionMode = false;
    clearSelection();
    notifyListeners();
  }

  void toggleItem(String id) {
    if (!selectedItemIds.add(id)) selectedItemIds.remove(id);
    notifyListeners();
  }

  void toggleFolder(String id) {
    if (!selectedFolderIds.add(id)) selectedFolderIds.remove(id);
    notifyListeners();
  }

  void selectAll({
    required Iterable<String> itemIds,
    required Iterable<String> folderIds,
  }) {
    selectedItemIds
      ..clear()
      ..addAll(itemIds);
    selectedFolderIds
      ..clear()
      ..addAll(folderIds);
    notifyListeners();
  }

  void clearSelection() {
    selectedItemIds.clear();
    selectedFolderIds.clear();
    notifyListeners();
  }

  void pruneSelection({
    required Iterable<String> itemIds,
    required Iterable<String> folderIds,
  }) {
    final items = itemIds.toSet();
    final folders = folderIds.toSet();
    selectedItemIds.removeWhere((id) => !items.contains(id));
    selectedFolderIds.removeWhere((id) => !folders.contains(id));
  }

  int get selectedCount => selectedItemIds.length + selectedFolderIds.length;

  void refresh() => notifyListeners();
}

class MediaBrowserFolderRow extends StatelessWidget {
  const MediaBrowserFolderRow({
    super.key,
    required this.folder,
    required this.itemCount,
    required this.onOpen,
    required this.onAction,
    this.selectionMode = false,
    this.selected = false,
    this.onSelected,
    this.parent = false,
    this.extraActions = const [],
  });

  final MediaOrganizationFolder folder;
  final int itemCount;
  final VoidCallback onOpen;
  final ValueChanged<String> onAction;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool?>? onSelected;
  final bool parent;
  final List<SiteLensGlassMenuAction<String>> extraActions;

  @override
  Widget build(BuildContext context) {
    final leading = selectionMode
        ? Checkbox(
            value: selected,
            onChanged: onSelected,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )
        : Icon(
            parent ? Icons.folder_open_rounded : Icons.folder_rounded,
            color: Theme.of(context).colorScheme.primary,
          );
    return SiteLensCompactRow(
      leading: leading,
      title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(parent ? '$itemCount 项 · 返回上一级' : '$itemCount 项'),
      trailing: parent
          ? const Icon(
              Icons.arrow_upward_rounded,
              size: SiteLensMetrics.compactIconSize,
            )
          : selectionMode
          ? const Icon(
              Icons.chevron_right,
              size: SiteLensMetrics.compactIconSize,
            )
          : SiteLensGlassMenuButton<String>(
              tooltip: '文件夹操作',
              icon: Icons.more_horiz,
              actions: [
                const SiteLensGlassMenuAction(
                  value: 'rename',
                  label: '重命名文件夹',
                  icon: Icons.drive_file_rename_outline,
                ),
                const SiteLensGlassMenuAction(
                  value: 'move',
                  label: '移动到文件夹',
                  icon: Icons.drive_file_move_outlined,
                ),
                const SiteLensGlassMenuAction(
                  value: 'copy',
                  label: '复制文件夹内容',
                  icon: Icons.copy_all_outlined,
                ),
                const SiteLensGlassMenuAction(
                  value: 'delete',
                  label: '删除文件夹内容',
                  icon: Icons.delete_outline,
                ),
                ...extraActions,
              ],
              onSelected: onAction,
            ),
      onTap: selectionMode ? () => onSelected?.call(!selected) : onOpen,
    );
  }
}

class MediaBrowserSelectionActions extends StatelessWidget {
  const MediaBrowserSelectionActions({
    super.key,
    required this.controller,
    required this.visibleItemIds,
    required this.visibleFolderIds,
    required this.onAction,
    this.extraActions = const [],
    this.onExtraAction,
  });

  final MediaBrowserController controller;
  final Iterable<String> visibleItemIds;
  final Iterable<String> visibleFolderIds;
  final ValueChanged<String> onAction;
  final List<SiteLensGlassMenuAction<String>> extraActions;
  final ValueChanged<String>? onExtraAction;

  @override
  Widget build(BuildContext context) {
    final hasSelection = controller.selectedCount > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '全选',
          icon: const Icon(Icons.select_all),
          onPressed: controller.busy
              ? null
              : () => controller.selectAll(
                  itemIds: visibleItemIds,
                  folderIds: visibleFolderIds,
                ),
        ),
        SiteLensGlassMenuButton<String>(
          tooltip: '批量操作',
          icon: Icons.more_horiz,
          iconWidget: controller.busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          actions: [
            SiteLensGlassMenuAction(
              value: 'move',
              label: '移动到文件夹',
              icon: Icons.drive_file_move_outlined,
              enabled: !controller.busy && hasSelection,
            ),
            SiteLensGlassMenuAction(
              value: 'copy',
              label: '复制',
              icon: Icons.copy_outlined,
              enabled: !controller.busy && hasSelection,
            ),
            SiteLensGlassMenuAction(
              value: 'delete',
              label: '删除',
              icon: Icons.delete_outline,
              enabled: !controller.busy && hasSelection,
            ),
            ...extraActions.map(
              (action) => SiteLensGlassMenuAction<String>(
                value: 'extra:${action.value}',
                label: action.label,
                icon: action.icon,
                enabled: !controller.busy && hasSelection && action.enabled,
              ),
            ),
          ],
          onSelected: (value) {
            if (value.startsWith('extra:')) {
              onExtraAction?.call(value.substring(6));
            } else {
              onAction(value);
            }
          },
        ),
        IconButton(
          tooltip: '清除选择',
          icon: const Icon(Icons.remove_done),
          onPressed: controller.busy ? null : controller.clearSelection,
        ),
        IconButton(
          tooltip: '退出选择',
          icon: const Icon(Icons.close),
          onPressed: controller.busy ? null : controller.exitSelection,
        ),
      ],
    );
  }
}

List<SiteLensGlassMenuAction<String>> mediaBrowserFileMenuActions({
  bool canRename = true,
  bool canCopy = true,
  bool canDelete = true,
  bool enabled = true,
  List<SiteLensGlassMenuAction<String>> extraActions = const [],
}) => [
  if (canRename)
    SiteLensGlassMenuAction(
      value: 'rename',
      label: '重命名',
      icon: Icons.drive_file_rename_outline,
      enabled: enabled,
    ),
  SiteLensGlassMenuAction(
    value: 'move',
    label: '移动到文件夹',
    icon: Icons.drive_file_move_outlined,
    enabled: enabled,
  ),
  if (canCopy)
    SiteLensGlassMenuAction(
      value: 'copy',
      label: '复制',
      icon: Icons.copy_outlined,
      enabled: enabled,
    ),
  if (canDelete)
    SiteLensGlassMenuAction(
      value: 'delete',
      label: '删除',
      icon: Icons.delete_outline,
      enabled: enabled,
    ),
  ...extraActions,
];

Future<String?> showMediaBrowserNameDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required String label,
  String? suffix,
}) async {
  final controller = TextEditingController(text: initial);
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => SiteLensAlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 200,
          decoration: InputDecoration(labelText: label, suffixText: suffix),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

class MediaBrowserFolderChoice {
  const MediaBrowserFolderChoice({required this.confirmed, this.folderId});

  final bool confirmed;
  final String? folderId;
}

Future<MediaBrowserFolderChoice> showMediaBrowserFolderPicker(
  BuildContext context,
  MediaOrganizationService organization, {
  String title = '选择目标文件夹',
  Set<String> excludedFolderIds = const {},
}) async {
  await organization.restore();
  if (!context.mounted) return const MediaBrowserFolderChoice(confirmed: false);
  return await showModalBottomSheet<MediaBrowserFolderChoice>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) {
          final folders = organization.folders
              .where((folder) => !excludedFolderIds.contains(folder.id))
              .toList();
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
              ),
              child: ListView.builder(
                itemCount: folders.length + 1,
                itemBuilder: (_, index) {
                  final colors = SiteLensColors.of(sheetContext);
                  if (index == 0) {
                    return Theme(
                      data: siteLensQuietInteractionTheme(sheetContext),
                      child: ListTile(
                        focusColor: colors.rowInteractionOverlay,
                        hoverColor: colors.rowInteractionOverlay,
                        splashColor: colors.rowInteractionOverlay,
                        leading: const Icon(Icons.home_outlined),
                        title: const Text('媒体根目录'),
                        onTap: () => Navigator.pop(
                          sheetContext,
                          const MediaBrowserFolderChoice(confirmed: true),
                        ),
                      ),
                    );
                  }
                  final folder = folders[index - 1];
                  return Theme(
                    data: siteLensQuietInteractionTheme(sheetContext),
                    child: ListTile(
                      focusColor: colors.rowInteractionOverlay,
                      hoverColor: colors.rowInteractionOverlay,
                      splashColor: colors.rowInteractionOverlay,
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(_folderPath(organization, folder)),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        MediaBrowserFolderChoice(
                          confirmed: true,
                          folderId: folder.id,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ) ??
      const MediaBrowserFolderChoice(confirmed: false);
}

Future<bool> confirmMediaBrowserDelete(
  BuildContext context, {
  required String title,
  required String message,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SiteLensAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ) ??
    false;

Future<MediaBrowserBatchResult> runMediaBrowserDelete(
  BuildContext context, {
  required MediaOrganizationService organization,
  required MediaBrowserOperations operations,
  required Iterable<String> itemIds,
  required String title,
  required String message,
}) async {
  final ids = itemIds.toSet();
  if (ids.isEmpty) return const MediaBrowserBatchResult.empty();
  final blocked = <String, String>{};
  for (final id in ids) {
    final reason = await operations.preflightDelete(id);
    if (reason != null) blocked[id] = reason;
  }
  if (blocked.isNotEmpty) {
    throw StateError('有 ${blocked.length} 项无法删除：${blocked.values.join('；')}');
  }
  if (!context.mounted) return const MediaBrowserBatchResult.empty();
  if (!await confirmMediaBrowserDelete(
    context,
    title: title,
    message: message,
  )) {
    return const MediaBrowserBatchResult.empty();
  }
  final succeeded = <String>[];
  final failed = <String, String>{};
  for (final id in ids) {
    try {
      await operations.deleteItem(id);
      succeeded.add(id);
      await organization.removeItems([id]);
    } catch (error) {
      failed[id] = error.toString();
    }
  }
  return MediaBrowserBatchResult(succeeded: succeeded, failed: failed);
}

Future<MediaBrowserBatchResult> runMediaBrowserCopy(
  BuildContext context, {
  required MediaOrganizationService organization,
  required MediaBrowserOperations operations,
  required Iterable<String> itemIds,
  required String? destination,
}) async {
  final ids = itemIds.toSet();
  if (ids.isEmpty) return const MediaBrowserBatchResult.empty();
  final blocked = <String, String>{};
  for (final id in ids) {
    final reason = await operations.preflightCopy(id);
    if (reason != null) blocked[id] = reason;
  }
  if (blocked.isNotEmpty) {
    throw StateError('有 ${blocked.length} 项不能复制：${blocked.values.join('；')}');
  }
  final succeeded = <String>[];
  final failed = <String, String>{};
  for (final id in ids) {
    String? copiedId;
    try {
      copiedId = await operations.copyItem(id);
      await organization.clonePlacement(id, copiedId, folderId: destination);
      succeeded.add(copiedId);
    } catch (error) {
      if (copiedId != null) {
        var deleted = false;
        try {
          await operations.deleteItem(copiedId);
          deleted = true;
        } catch (_) {
          // Preserve the original failure; the next catalog restore can
          // reconcile the still-indexed copy if the provider rejects cleanup.
        }
        if (deleted) await organization.removeItems([copiedId]);
      }
      failed[id] = error.toString();
    }
  }
  return MediaBrowserBatchResult(succeeded: succeeded, failed: failed);
}

Future<MediaBrowserBatchResult> runMediaBrowserCopySelection(
  BuildContext context, {
  required MediaOrganizationService organization,
  required MediaBrowserOperations operations,
  required Iterable<String> itemIds,
  required Iterable<String> folderIds,
  required String? destination,
}) async {
  final roots = folderIds
      .toSet()
      .where(
        (id) => !folderIds.any(
          (other) =>
              other != id && organization.descendantsOf(other).contains(id),
        ),
      )
      .toList();
  final selected = <String>{...itemIds};
  for (final folderId in roots) {
    selected.addAll(organization.itemIdsInFolder(folderId));
  }
  if (selected.isEmpty && roots.isEmpty) {
    return const MediaBrowserBatchResult.empty();
  }
  for (final id in selected) {
    final reason = await operations.preflightCopy(id);
    if (reason != null) throw StateError(reason);
  }
  final mapping = roots.isEmpty
      ? const <String, String>{}
      : await organization.copyFolderTrees(roots, destination);
  final succeeded = <String>[];
  final failed = <String, String>{};
  for (final sourceId in selected) {
    String? copiedId;
    try {
      copiedId = await operations.copyItem(sourceId);
      final sourceFolder = organization.folderFor(sourceId);
      await organization.clonePlacement(
        sourceId,
        copiedId,
        folderId: mapping[sourceFolder] ?? destination,
      );
      succeeded.add(copiedId);
    } catch (error) {
      if (copiedId != null) {
        var deleted = false;
        try {
          await operations.deleteItem(copiedId);
          deleted = true;
        } catch (_) {
          // Keep the source error; the still-indexed copy can be cleaned up
          // during catalog restore when the provider becomes available.
        }
        if (deleted) await organization.removeItems([copiedId]);
      }
      failed[sourceId] = error.toString();
    }
  }
  if (failed.isNotEmpty) {
    for (final copiedId in succeeded) {
      try {
        await operations.deleteItem(copiedId);
      } catch (_) {}
      await organization.removeItems([copiedId]);
    }
    succeeded.clear();
    for (final root in roots) {
      final copy = mapping[root];
      if (copy != null) await organization.removeFolderTree(copy);
    }
  }
  return MediaBrowserBatchResult(succeeded: succeeded, failed: failed);
}

Future<MediaBrowserBatchResult> runMediaBrowserDeleteSelection(
  BuildContext context, {
  required MediaOrganizationService organization,
  required MediaBrowserOperations operations,
  required Iterable<String> itemIds,
  required Iterable<String> folderIds,
  required String title,
  required String message,
}) async {
  final roots = folderIds
      .toSet()
      .where(
        (id) => !folderIds.any(
          (other) =>
              other != id && organization.descendantsOf(other).contains(id),
        ),
      )
      .toList();
  final selected = <String>{...itemIds};
  for (final folderId in roots) {
    selected.addAll(organization.itemIdsInFolder(folderId));
  }
  final result = await runMediaBrowserDelete(
    context,
    organization: organization,
    operations: operations,
    itemIds: selected,
    title: title,
    message: message,
  );
  if (result.failed.isEmpty) {
    for (final folderId in roots) {
      await organization.removeFolderTree(folderId);
    }
  }
  return result;
}

Future<void> runMediaBrowserMove({
  required BuildContext context,
  required MediaOrganizationService organization,
  required Iterable<String> itemIds,
  required Iterable<String> folderIds,
  required String? currentFolderId,
}) async {
  final selectedItems = itemIds.toSet();
  final selectedFolders = folderIds.toSet();
  if (selectedItems.isEmpty && selectedFolders.isEmpty) return;
  final excluded = <String>{
    ...selectedFolders,
    for (final folderId in selectedFolders)
      ...organization.descendantsOf(folderId),
  };
  final choice = await showMediaBrowserFolderPicker(
    context,
    organization,
    excludedFolderIds: excluded,
  );
  if (!context.mounted || !choice.confirmed) return;
  await organization.moveSelection(
    folderIds: selectedFolders,
    itemIds: selectedItems,
    destination: choice.folderId,
  );
}

Future<MediaBrowserBatchResult> runMediaBrowserFolderCopy(
  BuildContext context, {
  required MediaOrganizationService organization,
  required MediaBrowserOperations operations,
  required String folderId,
}) async {
  final itemIds = organization.itemIdsInFolder(folderId);
  final blocked = <String, String>{};
  for (final id in itemIds) {
    final reason = await operations.preflightCopy(id);
    if (reason != null) blocked[id] = reason;
  }
  if (blocked.isNotEmpty) {
    throw StateError('有 ${blocked.length} 项不能复制：${blocked.values.join('；')}');
  }
  final excluded = {folderId, ...organization.descendantsOf(folderId)};
  if (!context.mounted) return const MediaBrowserBatchResult.empty();
  final choice = await showMediaBrowserFolderPicker(
    context,
    organization,
    excludedFolderIds: excluded,
  );
  if (!context.mounted || !choice.confirmed) {
    return const MediaBrowserBatchResult.empty();
  }
  final mapping = await organization.copyFolderTrees([
    folderId,
  ], choice.folderId);
  final succeeded = <String>[];
  final failed = <String, String>{};
  for (final sourceId in itemIds) {
    String? copiedId;
    try {
      copiedId = await operations.copyItem(sourceId);
      final sourceFolder = organization.folderFor(sourceId);
      await organization.clonePlacement(
        sourceId,
        copiedId,
        folderId: mapping[sourceFolder] ?? choice.folderId,
      );
      succeeded.add(copiedId);
    } catch (error) {
      if (copiedId != null) {
        try {
          await operations.deleteItem(copiedId);
        } catch (_) {
          // Keep the source error; cleanup can be retried during catalog restore.
        }
        await organization.removeItems([copiedId]);
      }
      failed[sourceId] = error.toString();
    }
  }
  if (failed.isNotEmpty) {
    for (final copiedId in succeeded) {
      try {
        await operations.deleteItem(copiedId);
      } catch (_) {}
      await organization.removeItems([copiedId]);
    }
    succeeded.clear();
    await organization.removeFolderTree(mapping[folderId]!);
  }
  return MediaBrowserBatchResult(succeeded: succeeded, failed: failed);
}

class MediaBrowserBatchResult {
  const MediaBrowserBatchResult({
    required this.succeeded,
    required this.failed,
  });

  const MediaBrowserBatchResult.empty()
    : succeeded = const [],
      failed = const {};

  final List<String> succeeded;
  final Map<String, String> failed;

  bool get partialFailure => failed.isNotEmpty && succeeded.isNotEmpty;
}

PopupMenuItem<String> mediaBrowserMenuItem(String value, String label) =>
    PopupMenuItem(value: value, child: Text(label));

String _folderPath(
  MediaOrganizationService organization,
  MediaOrganizationFolder folder,
) {
  final parts = <String>[];
  MediaOrganizationFolder? current = folder;
  final seen = <String>{};
  while (current != null && seen.add(current.id)) {
    parts.insert(0, current.name);
    current = current.parentId == null
        ? null
        : organization.folder(current.parentId!);
  }
  return parts.join(' / ');
}
