import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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
  static Future<void> _pendingWrites = Future<void>.value();
  @visibleForTesting
  static Future<Directory> Function()? pendingDirectoryProvider;

  static const _pendingFileName = 'site_lens_pending_errors.jsonl';

  static void detach(AppErrorLogger logger) {
    if (identical(_current, logger)) _current = null;
  }

  static void capture(
    Object error, {
    required String module,
    String? context,
    String level = 'error',
    StackTrace? stack,
  }) {
    final logger = _current;
    if (logger == null) {
      _queuePending(
        error: error,
        module: module,
        context: context,
        level: level,
        stack: stack,
      );
      return;
    }
    unawaited(
      logger.record(
        error,
        module: module,
        context: context,
        level: level,
        stack: stack,
      ),
    );
  }

  Future<void> record(
    Object error, {
    required String module,
    String? context,
    String level = 'error',
    StackTrace? stack,
  }) async {
    await recordMessage(
      message: readableError(error),
      details: _redact(error.toString()),
      module: module,
      context: context,
      level: level,
      stack: stack,
    );
  }

  Future<bool> recordMessage({
    required String message,
    required String details,
    required String module,
    String? context,
    String level = 'error',
    StackTrace? stack,
    bool deduplicateContext = false,
  }) async {
    try {
      await db.appendAppError(
        level: level,
        module: _clip(module, 80),
        message: _clip(message, 240),
        details: _clip(_withStack(details, stack), 8000),
        context: context == null ? null : _clip(_redactContext(context), 300),
        deduplicateContext: deduplicateContext,
      );
      return true;
    } catch (_) {
      // Diagnostics must never make a failed operation fail again.
      return false;
    }
  }

  /// Imports errors written before the database became available. The file is
  /// moved out of the way first so an error captured during import cannot
  /// overwrite the batch currently being recovered.
  Future<void> recoverPending() async {
    final file = await _pendingFile();
    if (file == null || !await file.exists()) return;
    final processing = File('${file.path}.processing');
    try {
      if (await processing.exists()) await processing.delete();
      await file.rename(processing.path);
      final lines = await processing.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final value = jsonDecode(line) as Map<String, dynamic>;
          await recordMessage(
            message: value['message'] as String? ?? '启动前异常',
            details: value['details'] as String? ?? '无详细信息',
            module: value['module'] as String? ?? 'startup',
            context: value['context'] as String?,
            level: value['level'] as String? ?? 'error',
            stack: _stack(value['stack'] as String?),
          );
        } catch (_) {
          // A malformed pending row must not prevent later rows from loading.
        }
      }
      await processing.delete();
    } catch (_) {
      // Keep the batch for the next startup if the database or filesystem is
      // temporarily unavailable. New errors are appended to the live file.
      try {
        if (await processing.exists()) {
          await processing.copy(file.path);
          await processing.delete();
        }
      } catch (_) {}
    }
  }

  /// Drains Android process and WebView renderer reports written before Dart
  /// had a chance to initialize its database logger.
  Future<void> recoverNativeReports() async {
    try {
      final rows = await const MethodChannel('site_lens/diagnostics')
          .invokeListMethod<String>('drain');
      final acknowledged = <String>[];
      for (final row in rows ?? const <String>[]) {
        try {
          final value = jsonDecode(row) as Map<String, dynamic>;
          final imported = await recordMessage(
            message: value['message'] as String? ?? '原生异常',
            details: value['details'] as String? ?? row,
            module: value['module'] as String? ?? 'android',
            context: value['reportId'] == null
                ? value['context'] as String?
                : 'native-report:${value['reportId']}',
            level: value['level'] as String? ?? 'error',
            deduplicateContext: value['reportId'] != null,
          );
          if (imported) acknowledged.add(row);
        } catch (_) {
          if (await recordMessage(
            message: '原生异常',
            details: row,
            module: 'android',
          )) {
            acknowledged.add(row);
          }
        }
      }
      if (acknowledged.isNotEmpty) {
        await const MethodChannel('site_lens/diagnostics')
            .invokeMethod<void>('ack', {'rows': acknowledged});
      }
    } catch (_) {
      // The channel is Android-only and may be unavailable in tests/iOS.
    }
  }

  static StackTrace? _stack(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : StackTrace.fromString(text);
  }

  static String _withStack(String details, StackTrace? stack) {
    final clean = _redact(details);
    final stackText = stack?.toString().trim();
    if (stackText == null || stackText.isEmpty) return clean;
    return '$clean\n堆栈：${_redact(stackText)}';
  }

  static void _queuePending({
    required Object error,
    required String module,
    required String? context,
    required String level,
    required StackTrace? stack,
  }) {
    final payload = jsonEncode({
      'happenedAt': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'module': module,
      'message': readableError(error),
      'details': _redact(error.toString()),
      'stack': stack?.toString(),
      'context': context == null ? null : _redact(context),
    });
    _pendingWrites = _pendingWrites.then((_) async {
      try {
        final file = await _pendingFile();
        if (file == null) return;
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '$payload\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // Never let diagnostics alter the original exception path.
      }
    });
  }

  static Future<File?> _pendingFile() async {
    try {
      final directory =
          await (pendingDirectoryProvider?.call() ??
              getApplicationSupportDirectory());
      return File('${directory.path}/$_pendingFileName');
    } catch (_) {
      return null;
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

  /// Context is an index used for deduplication and grouping. Keep it free of
  /// page URLs even when a caller accidentally includes one; details retain
  /// the existing host/path redaction for human diagnosis.
  static String _redactContext(String value) {
    final withoutUrls = value.replaceAll(
      RegExp(r'https?://[^\s,)]+', caseSensitive: false),
      '[网址已隐藏]',
    );
    return _redact(withoutUrls);
  }

  static String _clip(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max - 1)}…';
}
