/// Internal error for a non-2xx API reply. Not exported from the package.
library;

import 'dart:io' show HttpDate;

/// Thrown by the SDK's request layer when the API answers outside 200–299.
///
/// `toString()` keeps the exact text 1.1.2 produced, because `submitForm`,
/// `refineText` and other public methods let this error reach the host app.
/// [status] and [retryAfterMs] let the retry queue and the 429 pause read the
/// reply without parsing that text.
class EncatchHttpException implements Exception {
  const EncatchHttpException(this.status, this.body, {this.retryAfterMs});

  final int status;
  final String body;

  /// From the `Retry-After` header (seconds or an HTTP date), when present.
  final int? retryAfterMs;

  @override
  String toString() => 'Exception: Encatch API error: status $status — $body';
}

/// Parses a `Retry-After` header: a delay in seconds, or an HTTP date. Returns
/// milliseconds from [nowMs], or null when the header is missing or invalid.
int? parseRetryAfter(String? value, int nowMs) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(trimmed)) {
    return (double.parse(trimmed) * 1000).round();
  }
  try {
    final at = HttpDate.parse(trimmed).millisecondsSinceEpoch;
    return at > nowMs ? at - nowMs : 0;
  } catch (_) {
    return null;
  }
}

/// The HTTP status of an error from the request layer, if it has one.
int? httpStatusOf(Object error) {
  if (error is EncatchHttpException) return error.status;
  final match = RegExp(r'status (\d+)').firstMatch(error.toString());
  return match == null ? null : int.tryParse(match.group(1)!);
}
