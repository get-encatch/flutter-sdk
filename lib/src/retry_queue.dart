/// Retry queue for identify, track-event and track-screen calls.
///
/// - One flush runs at a time. A `flush()` call made during a run waits for
///   that run, and the run keeps going until nothing is due, so a call queued
///   while another is in flight is still sent.
/// - A 5xx reply or a network failure is retried: 3 attempts in all, 2 s after
///   the first failure and 4 s after the second. Each item carries the time of
///   its next attempt; an item that is backing off does not hold up the others.
/// - A 4xx reply drops that item only, and the flush goes on.
/// - While a 429 pause is on (see rate_limit.dart), queued items are held.
/// - Flushed again when the app returns to the foreground.
/// - The queue's labels are written to SharedPreferences, but the calls
///   themselves are not, so nothing is re-sent after an app restart.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'http_error.dart';
import 'internals.dart' as internals;
import 'rate_limit.dart' as rate;
import 'storage.dart' show storageKeyRetryQueue;

const _maxRetries = 3;
const _baseBackoffMs = 1000;

class _QueueItem {
  final String id;
  Future<void> Function() fn;
  int retries;
  final int maxRetries;
  final int createdAt;
  final String label;

  /// Earliest time (ms since the epoch) this item may be sent.
  int nextAttemptAt = 0;

  /// Called when the item is given up on: a 4xx reply, or no attempts left.
  final void Function()? onDropped;

  _QueueItem({
    required this.id,
    required this.fn,
    required this.label,
    this.maxRetries = _maxRetries,
    required this.createdAt,
    this.onDropped,
  }) : retries = 0;
}

class _SerializableQueueItem {
  final String id;
  final int retries;
  final int maxRetries;
  final int createdAt;
  final String label;

  _SerializableQueueItem({
    required this.id,
    required this.retries,
    required this.maxRetries,
    required this.createdAt,
    required this.label,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'retries': retries,
    'maxRetries': maxRetries,
    'createdAt': createdAt,
    'label': label,
  };

  factory _SerializableQueueItem.fromJson(Map<String, dynamic> json) =>
      _SerializableQueueItem(
        id: json['id'] as String,
        retries: json['retries'] as int,
        maxRetries: json['maxRetries'] as int,
        createdAt: json['createdAt'] as int,
        label: json['label'] as String,
      );
}

// In-memory queue (runtime)
final _queue = <_QueueItem>[];

/// The flush in progress, if any.
Future<void>? _running;

/// Wakes the queue when the next backing-off item becomes due.
Timer? _wakeTimer;

int _idCounter = 0;

// ============================================================================
// Internal helpers
// ============================================================================

/// 4xx client errors are not retried: they won't succeed.
bool _isClientError(Object err) {
  final status = httpStatusOf(err);
  return status != null && status >= 400 && status < 500;
}

/// 2 s after the first failure, 4 s after the second.
int _backoffMs(int retries) => _baseBackoffMs * (1 << retries);

Future<void> _persistQueue() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final serializable = _queue
        .map(
          (item) => _SerializableQueueItem(
            id: item.id,
            retries: item.retries,
            maxRetries: item.maxRetries,
            createdAt: item.createdAt,
            label: item.label,
          ).toJson(),
        )
        .toList();
    await prefs.setString(storageKeyRetryQueue, jsonEncode(serializable));
  } catch (_) {
    // ignore storage failures
  }
}

Future<void> _removeFromPersisted(String id) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKeyRetryQueue);
    if (raw == null) return;
    final items = (jsonDecode(raw) as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(_SerializableQueueItem.fromJson)
        .where((i) => i.id != id)
        .map((i) => i.toJson())
        .toList();
    await prefs.setString(storageKeyRetryQueue, jsonEncode(items));
  } catch (_) {
    // ignore
  }
}

Future<void> _drop(_QueueItem item) async {
  _queue.remove(item);
  await _removeFromPersisted(item.id);
}

/// Gives up on [item]: it failed and will not be tried again.
Future<void> _giveUp(_QueueItem item) async {
  await _drop(item);
  try {
    item.onDropped?.call();
  } catch (_) {
    // a callback must not break the flush
  }
}

/// The first queued item whose next attempt is due at [now], in queue order.
_QueueItem? _firstDue(int now) {
  for (final item in _queue) {
    if (item.nextAttemptAt <= now) return item;
  }
  return null;
}

// ============================================================================
// Public API
// ============================================================================

/// Enqueue a retriable API call.
///
/// [label] is a human-readable name used for debug output.
/// [fn] is the async function to execute (closure capturing the request payload).
/// [maxRetries] is the number of attempts in all (default: 3).
/// [onDropped] is called if the call is given up on (a 4xx reply, or no
/// attempts left).
void enqueue(
  String label,
  Future<void> Function() fn, {
  int maxRetries = _maxRetries,
  void Function()? onDropped,
}) {
  final now = internals.nowMs();
  final item = _QueueItem(
    id: '$now-${(_idCounter++).toRadixString(36)}',
    fn: fn,
    label: label,
    maxRetries: maxRetries,
    createdAt: now,
    onDropped: onDropped,
  );
  _queue.add(item);
  _persistQueue();
}

/// Sends every queued call that is due, one at a time, in order.
///
/// Only one flush runs at a time: a call made while one is running returns
/// that run's future. The run keeps going until nothing is due, so it also
/// sends calls queued while it was running.
Future<void> flush() {
  return _running ??= _run().whenComplete(() {
    _running = null;
    _afterRun();
  });
}

Future<void> _run() async {
  _wakeTimer?.cancel();
  _wakeTimer = null;

  while (true) {
    // During a 429 pause, queued calls are held. The pause-end listener in
    // encatch.dart flushes again when it is over.
    if (rate.isPaused(rate.Bucket.tracking)) break;
    final item = _firstDue(internals.nowMs());
    if (item == null) break;

    try {
      // The request layer reads the attempt number from the zone, for the
      // debug hooks.
      await runZoned(
        item.fn,
        zoneValues: {internals.attemptZoneKey: item.retries + 1},
      );
      await _drop(item);
    } catch (err) {
      if (_isClientError(err)) {
        await _giveUp(item);
        internals.sdkLogger.debug(
          'Retry queue: dropping "${item.label}" (client error, no retry): $err',
        );
        continue;
      }
      item.retries += 1;
      if (item.retries >= item.maxRetries) {
        await _giveUp(item);
        internals.sdkLogger.debug(
          'Retry queue: dropping "${item.label}" after ${item.maxRetries} attempts: $err',
        );
      } else {
        item.nextAttemptAt = internals.nowMs() + _backoffMs(item.retries);
        await _persistQueue();
      }
    }
  }
}

/// After a run: start another if something became due in the meantime (a call
/// queued just as the run was ending), otherwise wake when the next item's
/// backoff ends.
void _afterRun() {
  if (_queue.isEmpty || rate.isPaused(rate.Bucket.tracking)) return;
  final now = internals.nowMs();
  if (_firstDue(now) != null) {
    flush().catchError((_) {});
    return;
  }
  final next = _queue
      .map((item) => item.nextAttemptAt)
      .reduce((a, b) => a < b ? a : b);
  _wakeTimer?.cancel();
  _wakeTimer = Timer(Duration(milliseconds: next - now), () {
    _wakeTimer = null;
    flush().catchError((_) {});
  });
}

/// Returns the current number of items in the in-memory queue.
int queueSize() => _queue.length;

/// Empties the in-memory queue. For the SDK's own tests only.
void clearForTest() {
  _queue.clear();
  _wakeTimer?.cancel();
  _wakeTimer = null;
  _running = null;
}

// ============================================================================
// AppLifecycleState listener: flush on foreground
// ============================================================================

_EncatchLifecycleObserver? _lifecycleObserver;

/// Starts listening for app lifecycle changes and flushes the queue when the
/// app comes to the foreground. Call once during SDK initialization.
void startAppLifecycleListener() {
  if (_lifecycleObserver != null) return; // already started
  _lifecycleObserver = _EncatchLifecycleObserver();
  WidgetsBinding.instance.addObserver(_lifecycleObserver!);
}

/// Removes the lifecycle listener. Call during SDK teardown.
void stopAppLifecycleListener() {
  if (_lifecycleObserver != null) {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
    _lifecycleObserver = null;
  }
}

class _EncatchLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      flush().catchError((_) {});
    }
  }
}
