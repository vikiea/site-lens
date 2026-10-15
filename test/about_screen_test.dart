import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:site_lens/ui/about_screen.dart';

void main() {
  testWidgets('about screen shows application metadata', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AboutScreen(
          packageInfoLoader: () async => PackageInfo(
            appName: 'Site Lens',
            packageName: 'dev.vikiea.site_lens',
            version: '0.2.0',
            buildNumber: '42',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('0.2.0'), findsOneWidget);
    expect(find.text('dev.vikiea.site_lens'), findsOneWidget);
    expect(find.text('GPL-3.0-or-later'), findsOneWidget);
  });
}
