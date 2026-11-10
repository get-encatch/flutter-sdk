import 'dart:io' show HttpDate;

import 'package:encatch_flutter/src/http_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the error text is the same as in 1.1.2', () {
    const error = EncatchHttpException(429, '{"error":"rate limit exceeded"}');
    expect(
      error.toString(),
      Exception(
        'Encatch API error: status 429 — {"error":"rate limit exceeded"}',
      ).toString(),
    );
    expect(error, isA<Exception>());
    expect(httpStatusOf(error), 429);
  });

  test('httpStatusOf reads the status from older error text too', () {
    expect(httpStatusOf(Exception('Encatch API error: status 503 — x')), 503);
    expect(httpStatusOf(Exception('socket closed')), isNull);
  });

  test('parseRetryAfter reads seconds and HTTP dates', () {
    const now = 1762700000000;
    expect(parseRetryAfter('60', now), 60000);
    expect(parseRetryAfter(' 1.5 ', now), 1500);
    expect(parseRetryAfter('0', now), 0);
    final in30s = DateTime.fromMillisecondsSinceEpoch(now + 30000, isUtc: true);
    expect(parseRetryAfter(HttpDate.format(in30s), now), 30000);
    final past = DateTime.fromMillisecondsSinceEpoch(now - 5000, isUtc: true);
    expect(parseRetryAfter(HttpDate.format(past), now), 0);
    expect(parseRetryAfter(null, now), isNull);
    expect(parseRetryAfter('', now), isNull);
    expect(parseRetryAfter('soon', now), isNull);
  });
}
