class DoubleBackExitController {
  DoubleBackExitController({this.window = const Duration(seconds: 2)});

  final Duration window;
  DateTime? _lastBack;

  bool handleBack(DateTime now) {
    final previous = _lastBack;
    if (previous != null && now.difference(previous) <= window) {
      _lastBack = null;
      return true;
    }
    _lastBack = now;
    return false;
  }

  void reset() => _lastBack = null;
}
