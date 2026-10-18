import 'dart:async';

import '../data/database.dart';
import '../network/transport.dart';

/// A process-wide sink used by framework, native and controller boundaries.
/// Logging is best effort and never changes the user-visible failure path.
class AppErrorLogger {
  AppErrorLogger(this.db) {
    _current = this;
  }

  final AppDatabase db;
  static AppErrorLogger? _current;

  static void detach(AppErrorLogger logger) {
    if (identical(_current, logger)) _current = null;
  }

  static void capture(
    Object error, {
    required String module,
    String? context,
    String level = 'error',
  }) {
    final logger = _current;
    if (logger == null) return;
    unawaited(
      logger.record(error, module: module, context: context, level: level),
    );
  }

  Future<void> record(
    Object error, {
    required String module,
    String? context,
    String level = 'error',
  }) => recordMessage(
    message: readableError(error),
    details: _redact(error.toString()),
    module: module,
    context: context,
    level: level,
  );

  Future<void> recordMessage({
    required String message,
    required String details,
    required String module,
    String? context,
    String level = 'error',
  }) async {
    try {
      await db.appendAppError(
        level: level,
        module: _clip(module, 80),
        message: _clip(message, 240),
        details: _clip(_redact(details), 1200),
        context: context == null ? null : _clip(_redact(context), 300),
      );
    } catch (_) {
      // Diagnostics must never make a failed operation fail again.
    }
  }

  static String _redact(String value) {
    var result = value.replaceAllMapped(
      RegExp(r'https?://[^\s,)]+', caseSensitive: false),
      (match) {
        final raw = match.group(0)!;
        final uri = Uri.tryParse(raw);
        if (uri == null || uri.host.isEmpty) return '[网址已隐藏]';
        final path = uri.path.isEmpty ? '/' : uri.path;
        return '${uri.scheme}://${uri.host}$path';
      },
    );
    result = result.replaceAll(
      RegExp(
        r'(auth[_-]?key|token|access[_-]?token|password|cookie|signature)=([^\s&,)]+)',
        caseSensitive: false,
      ),
      r'$1=[已隐藏]',
    );
    return result.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max - 1)}…';
}
