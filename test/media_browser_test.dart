import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/media/media_organization.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/media_browser.dart';
import 'package:site_lens/ui/ui_primitives.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  testWidgets('media browser folder actions use the shared glass menu', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.mistPine, Brightness.dark),
        home: Scaffold(
          body: MediaBrowserFolderRow(
            folder: const MediaOrganizationFolder(id: 'folder', name: '媒体文件夹'),
            itemCount: 3,
            onOpen: () {},
            onAction: selected.add,
            extraActions: const [
              SiteLensGlassMenuAction(
                value: 'export',
                label: '导出文件夹 MP4',
                icon: Icons.file_download_outlined,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('文件夹操作'));
    await tester.pumpAndSettle();

    expect(find.byType(SiteLensGlassMenuButton<String>), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SiteLensGlassSurface &&
            widget.role == SiteLensSurfaceRole.menu,
      ),
      findsOneWidget,
    );
    expect(find.text('重命名文件夹'), findsOneWidget);
    expect(find.text('导出文件夹 MP4'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);

    await tester.tap(find.text('导出文件夹 MP4'));
    await tester.pumpAndSettle();
    expect(selected, ['export']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media browser selection actions keep folder batch operations', (
    tester,
  ) async {
    final organization = MediaOrganizationService.reader(
      db: db,
      collection: 'test',
    );
    final controller = MediaBrowserController(organization: organization);
    controller.enterSelection();
    controller.selectedItemIds.add('item');
    final selected = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
        home: Scaffold(
          body: MediaBrowserSelectionActions(
            controller: controller,
            visibleItemIds: const ['item'],
            visibleFolderIds: const [],
            onAction: selected.add,
            extraActions: const [
              SiteLensGlassMenuAction(
                value: 'retry',
                label: '批量重试下载',
                icon: Icons.replay,
              ),
            ],
            onExtraAction: selected.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    expect(find.text('批量重试下载'), findsOneWidget);
    await tester.tap(find.text('批量重试下载'));
    await tester.pumpAndSettle();
    expect(selected, ['retry']);
    controller.dispose();
  });
}
