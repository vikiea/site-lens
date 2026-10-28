import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'background/health_worker.dart';
import 'data/database.dart';
import 'diagnostics/error_log.dart';
import 'diagnostics/startup_trace.dart';
import 'ui/app_controller.dart';
import 'ui/browser_dock.dart';
import 'ui/app_theme.dart';
import 'ui/glass_surface.dart';
import 'ui/navigation_observer.dart';
import 'ui/screens.dart';
import 'ui/update_notice.dart';

Future<void> main() async {
  final startup = StartupTrace.process;
  startup.markOnce(StartupPhase.appEntry);
  await runZonedGuarded(
    () async {
      // Framework initialization, error callbacks and runApp share this zone.
      WidgetsFlutterBinding.ensureInitialized();
      startup.markOnce(StartupPhase.bindingReady);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        startup.markOnce(StartupPhase.firstFrameworkFrame);
      });
      if (startup.enabled) {
        void firstRaster(List<FrameTiming> timings) {
          if (timings.isEmpty) return;
          final first = timings.first;
          startup.firstRasterFrame(
            buildUs: first.buildDuration.inMicroseconds,
            rasterUs: first.rasterDuration.inMicroseconds,
            totalUs: first.totalSpan.inMicroseconds,
          );
          WidgetsBinding.instance.removeTimingsCallback(firstRaster);
        }

        WidgetsBinding.instance.addTimingsCallback(firstRaster);
      }
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        AppErrorLogger.capture(
          details.exception,
          module: 'flutter',
          context: details.library,
          stack: details.stack,
        );
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        AppErrorLogger.capture(error, module: 'platform', stack: stack);
        return true;
      };
      try {
        final database = await startup.measure(
          StartupPhase.databaseOpen,
          AppDatabase.open,
        );
        final bootstrap = await startup.measure(
          StartupPhase.preferencesRead,
          () => readAppBootstrap(database),
        );
        // Liquid glass is composed through wrap() below and loads shader programs
        // on demand. Do not prewarm during Android startup: emulator Impeller
        // rasterization can crash while a warmup future is active.
        // WorkManager is started separately and does not block runApp; the
        // controller applies the stored schedule after its shared Future is ready.
        unawaited(HealthScheduler.initializeForAppStartup());
        runApp(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(database),
              appBootstrapProvider.overrideWithValue(bootstrap),
            ],
            child: const SiteLensApp(),
          ),
        );
      } catch (error, stack) {
        AppErrorLogger.capture(error, module: 'startup', stack: stack);
        runApp(
          MaterialApp(
            home: Scaffold(
              body: const SafeArea(
                child: Center(child: Text('本地数据库无法打开，请检查存储空间后重试。')),
              ),
            ),
          ),
        );
      }
    },
    (error, stack) {
      AppErrorLogger.capture(error, module: 'unhandled', stack: stack);
    },
  );
}

bool _isFlutterTestBinding() =>
    WidgetsBinding.instance.runtimeType.toString().contains('TestWidgets');

class SiteLensApp extends ConsumerWidget {
  const SiteLensApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: '择站 · Site Lens',
        navigatorKey: siteLensNavigatorKey,
        debugShowCheckedModeBanner: false,
        scrollBehavior: const SiteLensScrollBehavior(),
        theme: buildSiteLensTheme(
          app.themePreset,
          Brightness.light,
          glassOpacity: app.settings.glassOpacity,
        ),
        darkTheme: buildSiteLensTheme(
          app.themePreset,
          Brightness.dark,
          glassOpacity: app.settings.glassOpacity,
        ),
        themeMode: toThemeMode(app.themeModePreference),
        builder: (context, child) {
          final brightness = Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: siteLensSystemUiOverlayStyle(brightness),
            child: LiquidGlassWidgets.wrap(
              brightnessResolver: Theme.maybeBrightnessOf,
              // Start at standard, then let the package benchmark raster time.
              // The Site Lens strategy keeps content panels conservative unless
              // all-surfaces coverage is enabled for the selected quality.
              adaptiveQuality: !_isFlutterTestBinding(),
              adaptiveConfig: app.glassAdaptiveConfig,
              child: SiteLensGlassPolicyScope(
                strategy: SiteLensGlassQualityStrategy(
                  mode: app.settings.glassQualityMode,
                  allSurfacesHighQuality: app.settings.highQualityAllSurfaces,
                  webViewVisible: app.browserSurfaceActive,
                  hcppEffective: app.deviceDiagnostics.effectiveHcpp,
                  backgroundMode: app.background.mode,
                ),
                child: GlassAccessibilityScope(
                  // The material does not step down for high contrast; contrast is
                  // handled by the colour roles instead of by dropping the glass.
                  reduceTransparency: false,
                  // The update notice sits above the navigator so a completed
                  // download can surface on any page, WebView included.
                  child: SiteLensBackdrop(
                    background: app.background,
                    child: SiteLensUpdateNoticeLayer(
                      child: BrowserDock(
                        app: app,
                        child: child ?? const SizedBox(),
                      ),
                    ),
                  ),
                ),
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
