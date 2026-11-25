import 'package:flutter/widgets.dart';

/// The app's one [RouteObserver]: a screen that must react when a route
/// pushed above it pops (`RouteAware.didPopNext`) subscribes here. Wired into
/// `MaterialApp.navigatorObservers` in `main.dart`.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
