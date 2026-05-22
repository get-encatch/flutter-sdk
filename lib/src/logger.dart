/// Internal debug logger for the Encatch Flutter SDK.
/// Mirrors logger.ts from the React Native SDK.
///
/// Uses dart:developer log() + debugPrint so output appears both in the
/// Flutter DevTools "Logging" tab (filterable by name "Encatch") and in
/// the terminal — with no truncation thanks to debugPrint's chunking.
library;

import 'dart:convert';
import 'dart:developer' as dev;

const _levelDebug = 500;
const _levelWarn = 900;
const _levelError = 1000;

class EncatchLogger {
  final bool debugMode;

  const EncatchLogger({required this.debugMode});

  static String get _timestamp => DateTime.now().toString().substring(11, 23);

  void debug(String message, [dynamic data]) {
    if (!debugMode) return;
    _emit('🟢 $message', data, _levelDebug);
  }

  void warn(String message, [dynamic data]) {
    _emit('🟡 WARN: $message', data, _levelWarn);
  }

  void error(String message, [dynamic data]) {
    _emit('🔴 ERROR: $message', data, _levelError);
  }

  /// Logs request + response (or error) in a single block with duration.
  /// Call after awaiting the HTTP response so all data is available at once.
  void requestResponse({
    required String method,
    required String url,
    required Map<String, String> requestHeaders,
    required Map<String, dynamic> requestBody,
    required int durationMs,
    int? statusCode,
    Map<String, String>? responseHeaders,
    String? responseBody,
    Object? error,
  }) {
    if (!debugMode) return;

    final isError =
        error != null ||
        (statusCode != null && (statusCode < 200 || statusCode >= 300));
    final level = isError ? _levelError : _levelDebug;
    final statusLabel = statusCode != null ? ' $statusCode' : '';
    final icon = error != null ? '🔴' : (isError ? '🔴' : '📤📥');

    final buf = StringBuffer();
    buf.writeln('$icon $method$statusLabel $url');
    buf.writeln('⏱  $_timestamp  (${durationMs}ms)');

    // ── Request ──────────────────────────────────────
    buf.writeln();
    buf.writeln('── Request ─────────────────────────────────────────');
    buf.writeln('Headers:');
    for (final e in requestHeaders.entries) {
      final value = _shouldRedact(e.key) ? _redact(e.value) : e.value;
      buf.writeln('  ${e.key}: $value');
    }
    buf.writeln();
    buf.writeln('Body:');
    buf.writeln(_prettyJson(requestBody));

    // ── Response or Error ─────────────────────────────
    if (error != null) {
      buf.writeln();
      buf.writeln('── Error ────────────────────────────────────────────');
      buf.write(error.toString());
    } else if (statusCode != null) {
      buf.writeln();
      buf.writeln(
        '── Response$statusLabel ─────────────────────────────────────',
      );
      if (responseHeaders != null) {
        buf.writeln('Headers:');
        for (final e in responseHeaders.entries) {
          buf.writeln('  ${e.key}: ${e.value}');
        }
        buf.writeln();
      }
      buf.writeln('Body:');
      buf.write(_tryPrettyJson(responseBody ?? ''));
    }

    _emit2(buf.toString(), level);
  }

  void _emit(String message, dynamic data, int level) {
    final buf = StringBuffer();
    buf.write('$message  ⏱ $_timestamp');
    if (data != null) {
      buf.writeln();
      buf.writeln();
      buf.write(_tryPrettyJson(data is String ? data : data.toString()));
    }
    _emit2(buf.toString(), level);
  }

  static void _emit2(String output, int level) {
    dev.log(output, name: 'Encatch', level: level);
  }

  static bool _shouldRedact(String headerName) {
    final lower = headerName.toLowerCase();
    return lower.contains('key') || lower.contains('signature');
  }

  static String _prettyJson(Map<String, dynamic> json) {
    try {
      return const JsonEncoder.withIndent('  ').convert(json);
    } catch (_) {
      return json.toString();
    }
  }

  static String _tryPrettyJson(String raw) {
    if (raw.isEmpty) return '(empty)';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  static String _redact(String value) {
    if (value.length <= 8) return '••••••••';
    return '${value.substring(0, 4)}••••${value.substring(value.length - 4)}';
  }
}
