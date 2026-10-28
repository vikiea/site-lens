import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../diagnostics/error_log.dart';
import '../diagnostics/startup_trace.dart';
import 'app_controller.dart';
import 'app_theme.dart';
import 'glass_surface.dart';
import 'navigation_observer.dart';
import 'screens.dart' show BrowserScreen;
import 'ui_primitives.dart';
import 'ui_util.dart';

/// Floating layer for ordinary Flutter routes, including nested settings pages.
/// Place around MaterialApp.builder's navigator child, under the glass policy.
/// Route eligibility comes from the same observer installed on that navigator.
class BrowserDock extends StatelessWidget {
  const BrowserDock({
    super.key,
    required this.app,
    required this.child,
    this.observer,
    this.bottomClearance =
        SiteLensMetrics.navBarHeight + SiteLensMetrics.toolbarInset,
  });

  final AppController app;
  final Widget child;
  final SiteLensRouteObserver? observer;

  /// Space above the bottom safe area reserved for the app navigation chrome.
  final double bottomClearance;

  @override
  Widget build(BuildContext context) =>
      _BrowserDockOverlay(child: _BrowserDockBody(dock: this));
}

/// Keeps the outer Overlay and its entry stable while MaterialApp rebuilds.
/// Recreating Overlay.wrap on every app notification can briefly host the same
/// Navigator and OverlayEntry global keys in both the old and new trees.
class _BrowserDockOverlay extends StatefulWidget {
  const _BrowserDockOverlay({required this.child});

  final Widget child;

  @override
  State<_BrowserDockOverlay> createState() => _BrowserDockOverlayState();
}

class _BrowserDockOverlayState extends State<_BrowserDockOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    canSizeOverlay: true,
    opaque: true,
    builder: (_) => widget.child,
  );

  @override
  void didUpdateWidget(covariant _BrowserDockOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry
      ..remove()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(
    key: const ValueKey('site-lens-browser-dock-overlay'),
    initialEntries: [_entry],
  );
}

// The state lives inside the stable overlay so route notifications rebuild its
// entry in the same frame, and Material tooltips have a valid Overlay ancestor.
class _BrowserDockBody extends StatefulWidget {
  const _BrowserDockBody({required this.dock});
  final BrowserDock dock;
  AppController get app => dock.app;
  Widget get child => dock.child;
  SiteLensRouteObserver? get observer => dock.observer;
  double get bottomClearance => dock.bottomClearance;

  @override
  State<_BrowserDockBody> createState() => _BrowserDockState();
}

class _BrowserDockState extends State<_BrowserDockBody> {
  SiteLensRouteObserver get _observer =>
      widget.observer ?? browserRouteObserver;
  bool _expanded = false;
  bool _busy = false;
  String? _activeId;
  Offset? _drag;
  Offset? _pointerOrigin;
  Offset? _dockOrigin;
  bool _positionPending = false;
  bool _frameMarkPending = false;
  bool _changeScheduled = false;
  bool? _localRight;
  double? _localY;
  Future<void> _positionWrites = Future.value();

  ActiveBrowserSession? get _current {
    final active = widget.app.activeBrowser;
    return active != null && widget.app.browserTabs.contains(active)
        ? active
        : null;
  }

  bool get _eligible =>
      _current != null &&
      !widget.app.restoringData &&
      _observer.allowsBrowserDock &&
      MediaQuery.viewInsetsOf(context).bottom == 0;

  @override
  void initState() {
    super.initState();
    _activeId = _current?.id;
    widget.app.addListener(_changed);
    _observer.addListener(_changed);
  }

  @override
  void didUpdateWidget(_BrowserDockBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_changed);
      widget.app.addListener(_changed);
      _expanded = false;
      _localRight = null;
      _localY = null;
    }
    final oldObserver = oldWidget.observer ?? browserRouteObserver;
    if (oldObserver != _observer) {
      oldObserver.removeListener(_changed);
      _observer.addListener(_changed);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_eligible) _resetTransient();
  }

  void _resetTransient() {
    _expanded = false;
    _drag = null;
    _pointerOrigin = null;
    _dockOrigin = null;
  }

  void _changed() {
    if (!mounted) return;
    if (!(WidgetsBinding.instance.buildOwner?.debugBuilding ?? false)) {
      _applyChanged();
      return;
    }
    if (_changeScheduled) return;
    _changeScheduled = true;
    // Navigator can notify while it is still mounting/restoring routes. Defer
    // only that build-phase case so the dock never marks itself dirty during
    // the observer callback, while ordinary route changes stay synchronous.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _changeScheduled = false;
      if (!mounted) return;
      _applyChanged();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _applyChanged() {
    setState(() {
      final id = _current?.id;
      if (id != _activeId || !_eligible) _resetTransient();
      _activeId = id;
      if (!_positionPending && _drag == null) {
        _localRight = null;
        _localY = null;
      }
    });
  }

  @override
  void dispose() {
    widget.app.removeListener(_changed);
    _observer.removeListener(_changed);
    super.dispose();
  }

  Future<void> _open(String id) async {
    if (_busy || !_eligible || _current?.id != id) return;
    final app = widget.app;
    final tab = _current!;
    final route = _observer.topRoute;
    final revision = _observer.revision;
    final navigator = siteLensNavigatorKey.currentState;
    if (navigator == null) return;
    setState(() => _busy = true);
    try {
      await safely(context, () async {
        await app.activateTab(tab);
        if (!mounted ||
            !_eligible ||
            !identical(route, _observer.topRoute) ||
            revision != _observer.revision ||
            !identical(navigator, siteLensNavigatorKey.currentState) ||
            app.activeBrowser?.id != id ||
            !app.browserTabs.contains(tab)) {
          return;
        }
        setState(_resetTransient);
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: siteLensBrowserRouteName),
              builder: (_) => BrowserScreen(app: app, site: tab.site),
            ),
          ),
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(String id) async {
    if (_busy || !_eligible || _current?.id != id) return;
    final app = widget.app;
    final tab = _current!;
    setState(() => _busy = true);
    try {
      await safely(context, () async {
        await app.closeTab(tab);
        if (!mounted) return;
        // Closing can select a neighbour. Never activate it here: this route
        // still belongs to Flutter and metadata alone is enough for the dock.
        if (!app.browserTabs.contains(tab) || app.activeBrowser?.id != id) {
          setState(_resetTransient);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _savePosition(bool right, double y) {
    final app = widget.app;
    _positionPending = true;
    // Serialise end-of-gesture patches without replacing unrelated settings.
    final write = _positionWrites.then((_) async {
      try {
        await app.updateSettings({'dockRight': right, 'dockY': y});
      } catch (error) {
        AppErrorLogger.capture(error, module: 'ui');
        if (mounted) showError(context, error);
      }
    });
    _positionWrites = write;
    unawaited(
      write.whenComplete(() {
        if (!mounted || !identical(_positionWrites, write)) return;
        setState(() {
          _positionPending = false;
          _localRight = null;
          _localY = null;
        });
      }),
    );
  }

  void _markVisibleFrame() {
    final trace = widget.app.startupTrace;
    if (_frameMarkPending ||
        !trace.needsMark(StartupPhase.resumeEntryFrameworkFrame)) {
      return;
    }
    _frameMarkPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameMarkPending = false;
      if (mounted &&
          identical(trace, widget.app.startupTrace) &&
          _eligible &&
          _current != null) {
        trace.markOnce(
          StartupPhase.resumeEntryFrameworkFrame,
          itemCount: widget.app.browserTabs.length,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_eligible)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final safe = MediaQuery.paddingOf(context);
                final availableWidth = constraints.maxWidth - safe.horizontal;
                final top = safe.top + SiteLensMetrics.toolbarInset;
                final bottom =
                    constraints.maxHeight -
                    safe.bottom -
                    math.max(0, widget.bottomClearance);
                final handleWidth = SiteLensMetrics.browserDockWidth;
                final handleHeight = SiteLensMetrics.compactRowMinHeight;
                final scale = MediaQuery.textScalerOf(context);
                final barHeight = math.max(
                  SiteLensMetrics.toolbarHeight,
                  scale.scale(SiteLensTypography.rowTitle) +
                      SiteLensMetrics.itemGap * 2,
                );
                final height = _expanded ? barHeight : handleHeight;
                if (availableWidth < SiteLensMetrics.toolbarHeight * 3 ||
                    bottom - top < height) {
                  return const SizedBox.shrink();
                }
                _markVisibleFrame();
                final width = _expanded
                    ? math.min(360.0, availableWidth)
                    : SiteLensMetrics.toolbarHeight;
                final left = safe.left;
                final right = constraints.maxWidth - safe.right - width;
                final travel = bottom - top - height;
                final dockRight = _localRight ?? widget.app.settings.dockRight;
                final savedY = _localY ?? widget.app.settings.dockY;
                final y = savedY.isFinite ? savedY.clamp(0.0, 1.0) : 0.5;
                final position =
                    _drag ?? Offset(dockRight ? right : left, top + travel * y);
                final bounded = Offset(
                  position.dx.clamp(left, right),
                  position.dy.clamp(top, top + travel),
                );
                final tab = _current!;
                final label = tab.title.trim().isEmpty
                    ? tab.currentUrl.host
                    : tab.title;
                return Stack(
                  children: [
                    Positioned(
                      left: bounded.dx,
                      top: bounded.dy,
                      width: width,
                      height: height,
                      child: Listener(
                        onPointerCancel: (_) => setState(_resetTransient),
                        child: _expanded
                            ? SiteLensGlassSurface(
                                // The dock is mounted above the live native
                                // WebView while a browser tab is active. Keep
                                // it on the platform-view safety role so its
                                // surface never samples native pixels.
                                role: SiteLensSurfaceRole.platformView,
                                radius: SiteLensMetrics.inputRadius,
                                child: Row(
                                  children: [
                                    IconButton(
                                      tooltip: '收起浏览浮条',
                                      onPressed: _busy
                                          ? null
                                          : () => setState(
                                              () => _expanded = false,
                                            ),
                                      icon: Icon(
                                        dockRight
                                            ? Icons.chevron_right
                                            : Icons.chevron_left,
                                      ),
                                    ),
                                    Expanded(
                                      child: Semantics(
                                        button: true,
                                        label: '进入标签页 $label',
                                        child: InkWell(
                                          key: const ValueKey(
                                            'browser-dock-title',
                                          ),
                                          onTap: _busy
                                              ? null
                                              : () => unawaited(_open(tab.id)),
                                          child: SizedBox.expand(
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: ExcludeSemantics(
                                                child: SiteLensRowText(
                                                  label,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleSmall,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      key: const ValueKey('browser-dock-close'),
                                      tooltip: '关闭当前标签页',
                                      onPressed: _busy
                                          ? null
                                          : () => unawaited(_close(tab.id)),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              )
                            : Material(
                                type: MaterialType.transparency,
                                child: GestureDetector(
                                  key: const ValueKey('browser-dock-handle'),
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: _busy
                                      ? null
                                      : (details) {
                                          _pointerOrigin =
                                              details.globalPosition;
                                          _dockOrigin = bounded;
                                        },
                                  onPanUpdate: _busy
                                      ? null
                                      : (details) {
                                          if (_pointerOrigin == null ||
                                              _dockOrigin == null) {
                                            return;
                                          }
                                          final next =
                                              _dockOrigin! +
                                              details.globalPosition -
                                              _pointerOrigin!;
                                          setState(
                                            () => _drag = Offset(
                                              next.dx.clamp(left, right),
                                              next.dy.clamp(top, top + travel),
                                            ),
                                          );
                                        },
                                  onPanEnd: (_) {
                                    if (_drag == null) return;
                                    final end = _drag!;
                                    final nextRight =
                                        end.dx + width / 2 >=
                                        (left + right + width) / 2;
                                    final nextY = travel > 0
                                        ? ((end.dy - top) / travel).clamp(
                                            0.0,
                                            1.0,
                                          )
                                        : 0.0;
                                    setState(() {
                                      _resetTransient();
                                      _localRight = nextRight;
                                      _localY = nextY;
                                    });
                                    _savePosition(nextRight, nextY);
                                  },
                                  onPanCancel: () => setState(() {
                                    _drag = null;
                                    _pointerOrigin = null;
                                    _dockOrigin = null;
                                  }),
                                  child: Semantics(
                                    button: true,
                                    label:
                                        '展开浏览浮条，$label，${widget.app.browserTabs.length} 个标签页',
                                    hint: '可拖动到左侧或右侧并上下调整位置',
                                    child: InkWell(
                                      onTap: _busy
                                          ? null
                                          : () => setState(
                                              () => _expanded = true,
                                            ),
                                      child: Align(
                                        alignment: dockRight
                                            ? Alignment.centerRight
                                            : Alignment.centerLeft,
                                        child: SizedBox(
                                          width: handleWidth,
                                          height: height,
                                          child: SiteLensGlassSurface(
                                            key: const ValueKey(
                                              'browser-dock-handle-surface',
                                            ),
                                            // This handle is also painted over
                                            // the live native WebView.
                                            role: SiteLensSurfaceRole
                                                .platformView,
                                            radius: SiteLensMetrics.inputRadius,
                                            attachedEdge: dockRight
                                                ? SiteLensGlassEdge.right
                                                : SiteLensGlassEdge.left,
                                            child: Center(
                                              child: Icon(
                                                Icons.drag_indicator,
                                                size: SiteLensMetrics
                                                    .browserDockIconSize,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}
