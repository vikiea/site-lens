import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'background/health_worker.dart';
import 'data/database.dart';
import 'ui/app_controller.dart';
import 'ui/app_theme.dart';
import 'ui/glass_surface.dart';
import 'ui/navigation_observer.dart';
import 'ui/screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final database = await AppDatabase.open();
    try {
      await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    } catch (_) {
      // The library has a frosted fallback; a shader failure is not a DB error.
    }
    try {
      await const HealthScheduler().initialize();
    } catch (_) {
      /* Background scheduling is best effort. */
    }
    runApp(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const SiteLensApp(),
      ),
    );
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(child: Center(child: Text('本地数据库无法打开，请检查存储空间。\n$e'))),
        ),
      ),
    );
  }
}

class SiteLensApp extends ConsumerWidget {
  const SiteLensApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: '择站 · Site Lens',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const SiteLensScrollBehavior(),
        theme: buildSiteLensTheme(app.themePreset, Brightness.light),
        darkTheme: buildSiteLensTheme(app.themePreset, Brightness.dark),
        themeMode: toThemeMode(app.themeModePreference),
        builder: (context, child) {
          final brightness = Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: siteLensSystemUiOverlayStyle(brightness),
            child: LiquidGlassWidgets.wrap(
              brightnessResolver: Theme.maybeBrightnessOf,
              // iOS 27 liquid glass is the product's material, so the quality tier
              // is never negotiated down from it. Reduce Motion still applies.
              adaptiveQuality: false,
              child: GlassAccessibilityScope(
                // The material does not step down for high contrast; contrast is
                // handled by the colour roles instead of by dropping the glass.
                reduceTransparency: false,
                child: SiteLensBackdrop(child: child ?? const SizedBox()),
              ),
            ),
          );
        },
        navigatorObservers: [browserRouteObserver],
        home: const HomeScreen(),
      ),
    );
  }
}
