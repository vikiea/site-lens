import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const siteLensBrowserRouteName = 'browser-route';
const siteLensPlayerRouteName = 'player-route';

/// Keeps RouteAware browser callbacks and root overlay eligibility together.
/// Browser/player routes must carry their explicit names even while loading or
/// failed: native visibility alone cannot distinguish those states or popups.
class SiteLensRouteObserver extends RouteObserver<ModalRoute<dynamic>>
    with ChangeNotifier {
  final _routes = <Route<dynamic>>[];
  final _animations = <Route<dynamic>, Animation<double>>{};
  final _entering = <Route<dynamic>>{};
  final _leaving = <Route<dynamic>>{};
  final _overlayPopups = <Object>{};
  NavigatorState? _owner;
  bool _gesture = false;
  bool _notificationPending = false;
  bool _settlePending = false;
  bool _disposed = false;
  int _revision = 0;

  int get revision => _revision;

  Route<dynamic>? get topRoute => _routes.lastOrNull;

  bool get transitioning =>
      _gesture ||
      _entering.isNotEmpty ||
      _leaving.isNotEmpty ||
      _animations.values.any(
        (animation) =>
            animation.status == AnimationStatus.forward ||
            animation.status == AnimationStatus.reverse,
      );

  bool get allowsBrowserDock {
    final top = topRoute;
    if (top is PopupRoute<dynamic> || _overlayPopups.isNotEmpty) return false;
    return top is PageRoute<dynamic> &&
        top.opaque &&
        top.isCurrent &&
        top.settings.name != siteLensBrowserRouteName &&
        top.settings.name != siteLensPlayerRouteName &&
        !transitioning;
  }

  /// MenuAnchor overlays are not routes. Keep them in the same visibility and
  /// navigation-revision fence until they close or their owner is disposed.
  VoidCallback holdOverlayPopup() {
    final token = Object();
    if (_disposed) return () {};
    _overlayPopups.add(token);
    _revision++;
    _changed();
    return () {
      if (_disposed || !_overlayPopups.remove(token)) return;
      _revision++;
      _changed();
    };
  }

  void _checkOwner() {
    if (identical(_owner, navigator)) return;
    for (final animation in _animations.values) {
      animation.removeStatusListener(_animationChanged);
    }
    _animations.clear();
    _routes.clear();
    _entering.clear();
    _leaving.clear();
    _overlayPopups.clear();
    _gesture = false;
    _owner = navigator;
  }

  void _watch(Route<dynamic> route) {
    if (route is! TransitionRoute<dynamic>) return;
    final animation = route.animation;
    if (animation == null || _animations.containsKey(route)) return;
    _animations[route] = animation;
    if (animation.status != AnimationStatus.completed) _entering.add(route);
    animation.addStatusListener(_animationChanged);
  }

  void _forget(Route<dynamic> route) {
    _animations.remove(route)?.removeStatusListener(_animationChanged);
    _entering.remove(route);
    _leaving.remove(route);
  }

  void _animationChanged(AnimationStatus _) {
    // Flutter can temporarily complete a delegated transition before restarting
    // it in a post-frame callback. Only settle after all callbacks in that frame.
    if (!_settlePending &&
        _entering.any(
          (route) => _animations[route]?.status == AnimationStatus.completed,
        )) {
      _settlePending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scheduleMicrotask(() {
          _settlePending = false;
          if (_disposed) return;
          final count = _entering.length;
          _entering.removeWhere(
            (route) => _animations[route]?.status == AnimationStatus.completed,
          );
          if (_entering.length != count) _changed();
        });
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
    _changed();
  }

  void _changed() {
    // Navigator callbacks can run while the tree is locked. State is current
    // synchronously for action guards; defer only while a build is in progress.
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notificationPending) return;
    _notificationPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _checkOwner();
    _revision++;
    _routes.add(route);
    _watch(route);
    super.didPush(route, previousRoute);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _revision++;
    _routes.remove(route);
    _entering.remove(route);
    if (route is TransitionRoute<dynamic> && _animations.containsKey(route)) {
      _leaving.add(route);
      route.completed.then((_) {
        _forget(route);
        _changed();
      });
    }
    super.didPop(route, previousRoute);
    _animationChanged(AnimationStatus.reverse);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _revision++;
    _routes.remove(route);
    _forget(route);
    super.didRemove(route, previousRoute);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _checkOwner();
    _revision++;
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (oldRoute != null) {
      _routes.remove(oldRoute);
      _forget(oldRoute);
    }
    if (newRoute != null) {
      _routes.insert(index < 0 ? _routes.length : index, newRoute);
      _watch(newRoute);
    }
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _changed();
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _revision++;
    _gesture = true;
    super.didStartUserGesture(route, previousRoute);
    _changed();
  }

  @override
  void didStopUserGesture() {
    _gesture = false;
    super.didStopUserGesture();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final animation in _animations.values) {
      animation.removeStatusListener(_animationChanged);
    }
    _animations.clear();
    _routes.clear();
    _entering.clear();
    _leaving.clear();
    _overlayPopups.clear();
    super.dispose();
  }
}

final browserRouteObserver = SiteLensRouteObserver();

/// Navigator owned by [MaterialApp] in `main.dart`.
///
/// The in-app update notice renders above the navigator, so it needs a route
/// handle that does not depend on the widget tree below it.
final siteLensNavigatorKey = GlobalKey<NavigatorState>();
