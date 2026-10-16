import 'package:flutter/material.dart';

final browserRouteObserver = RouteObserver<ModalRoute<dynamic>>();

/// Navigator owned by [MaterialApp] in `main.dart`.
///
/// The in-app update notice renders above the navigator, so it needs a route
/// handle that does not depend on the widget tree below it.
final siteLensNavigatorKey = GlobalKey<NavigatorState>();
