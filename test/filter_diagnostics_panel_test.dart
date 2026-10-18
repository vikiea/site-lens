import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/filter/filter_service.dart';
import 'package:site_lens/ui/filter_diagnostics_panel.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

void main() {
  testWidgets('shows redacted current-document filter diagnostics', (
    tester,
  ) async {
    final compiled = const FilterCompiler().compile(
      '||ads.example^\nexample.com##.sponsor\nexample.com##+js(unknown,x)',
      snapshotId: 'snapshot-ui',
    );
    final session =
        HostSession(
            4,
            HostPurpose.browsing,
            HostCapabilities(
              platform: 'test',
              isolatedScripts: true,
              documentStart: false,
              privateProbes: true,
              reason: 'document-start unavailable',
            ),
          )
          ..url = 'https://example.com/watch?token=secret'
          ..errorKind = 'filterUnavailable';
    final snapshot = FilterSnapshot(
      id: 'snapshot-ui',
      sourceId: 1,
      version: 'v1',
      sourceUrl: Uri.parse('https://rules.example/list.txt'),
      sha256: 'b' * 64,
      state: FilterSnapshotState.degraded,
      createdAt: DateTime.utc(2026, 10, 17),
      fileRef: 'rules',
      unsupportedRuleCount: compiled.unsupportedRules.length,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilterDiagnosticsPanel(
            session: session,
            engine: compiled.engine,
            snapshot: snapshot,
            policy: const FilterPolicy(enabled: true),
            onAddException: () async {},
          ),
        ),
      ),
    );

    expect(find.textContaining('当前宿主未提供过滤接口'), findsOneWidget);
    expect(
      find.text('https://example.com/watch?token=%E2%80%A6'),
      findsOneWidget,
    );
    expect(find.text('未支持规则'), findsOneWidget);
    expect(find.text('本站加入例外'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
  });
}
