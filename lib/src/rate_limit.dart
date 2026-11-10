/// 429 pause. Internal; not exported from the package.
///
/// When the API answers 429, the SDK stops sending requests in that bucket
/// until `Retry-After` has passed, instead of hammering the server:
///  - the 429'd call is dropped (identify, track-event, track-screen, ping and
///    show-form are never retried after a 429),
///  - new calls in a paused bucket are skipped, apart from the latest
///    `identifyUser` and `submitForm`, which wait for the pause to end,
///  - calls already in the retry queue are held and sent once it ends.
///
/// Buckets follow how the gateway counts requests. Which endpoint belongs to
/// which bucket is configuration ([_bucketOf]), so it can follow the deployed
/// limits.
library;

import 'dart:async';

import 'internals.dart' as internals;

enum Bucket { tracking, showForm, submitForm, other }

/// Endpoint name (last path segment) to bucket.
const _bucketOf = <String, Bucket>{
  'identify-user': Bucket.tracking,
  'track-event': Bucket.tracking,
  'track-screen': Bucket.tracking,
  'ping': Bucket.tracking,
  'show-form': Bucket.showForm,
  'submit-form': Bucket.submitForm,
};

/// Pause used when a 429 has no valid `Retry-After` header.
const defaultPauseMs = 60 * 1000;

/// Longest pause, whatever `Retry-After` says.
const maxPauseMs = 5 * 60 * 1000;

final _pausedUntil = <Bucket, int>{};
final _timers = <Bucket, Timer>{};
final _listeners = <void Function(Bucket bucket)>[];

/// Bucket for an endpoint path such as
/// `engage-product/encatch/api/v2/encatch/track-event`.
Bucket bucketOf(String endpoint) =>
    _bucketOf[endpoint.split('/').last] ?? Bucket.other;

/// Starts (or extends) a pause after a 429. Warns once when a pause starts.
void pauseFor(Bucket bucket, int? retryAfterMs) {
  if (bucket == Bucket.other) return;
  final now = internals.nowMs();
  final wanted = (retryAfterMs != null && retryAfterMs >= 0)
      ? retryAfterMs
      : defaultPauseMs;
  final ms = wanted > maxPauseMs ? maxPauseMs : wanted;
  final until = now + ms;
  final current = _pausedUntil[bucket] ?? 0;
  if (until <= current) return;

  if (current <= now) {
    internals.sdkLogger.warn(
      'Rate limited (429): pausing ${bucket.name} requests for '
      '${(ms / 1000).ceil()} s. Calls made during the pause are skipped.',
    );
  }
  _pausedUntil[bucket] = until;
  _timers[bucket]?.cancel();
  _timers[bucket] = Timer(Duration(milliseconds: ms), () {
    _timers.remove(bucket);
    for (final listener in List.of(_listeners)) {
      try {
        listener(bucket);
      } catch (_) {
        // a listener must not break the others
      }
    }
  });
}

bool isPaused(Bucket bucket) => (_pausedUntil[bucket] ?? 0) > internals.nowMs();

/// Milliseconds until the bucket's pause ends (0 when not paused).
int pauseRemainingMs(Bucket bucket) {
  final left = (_pausedUntil[bucket] ?? 0) - internals.nowMs();
  return left > 0 ? left : 0;
}

/// Completes when [bucket] is not paused. Used by calls that must not be
/// dropped, such as a survey submit.
Future<void> waitUntilResumed(Bucket bucket) async {
  while (true) {
    final ms = pauseRemainingMs(bucket);
    if (ms <= 0) return;
    await Future<void>.delayed(Duration(milliseconds: ms));
  }
}

/// Calls [listener] whenever a pause ends. Returns a function that removes it.
void Function() onPauseEnd(void Function(Bucket bucket) listener) {
  _listeners.add(listener);
  return () => _listeners.remove(listener);
}

/// Clears every pause and listener (full SDK reset).
void clearPauses() {
  _pausedUntil.clear();
  for (final timer in _timers.values) {
    timer.cancel();
  }
  _timers.clear();
}

/// Removes every pause-end listener. For the SDK's own tests only.
void clearListenersForTest() => _listeners.clear();
