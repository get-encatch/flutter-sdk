/// Offline retry queue for failed API calls.
/// Mirrors retry-queue.ts from the React Native SDK.
///
/// - Persisted to SharedPreferences so requests survive app restarts.
/// - Automatically flushed when app returns to foreground (AppLifecycleState.resumed).
/// - Max 3 retries per request with exponential backoff (1s → 2s → 4s).
/// - Does NOT retry on 4xx client errors — these won't succeed on retry.
/// - Retries 5xx server errors and network failures.
/// - Only retries safe idempotent calls: identifyUser, trackEvent, trackScreen.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  _QueueItem({
    required this.id,
    required this.fn,
    required this.label,
    this.maxRetries = _maxRetries,
    required this.createdAt,
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

bool _isFlushing = false;

// ============================================================================
// Internal helpers
// ============================================================================

/// 4xx client errors should not be retried — they won't succeed.
bool _isClientError(Object err) {
  final msg = err.toString();
  final match = RegExp(r'status (\d+)').firstMatch(msg);
  if (match == null) return false;
  final status = int.tryParse(match.group(1) ?? '') ?? 0;
  return status >= 400 && status < 500;
}

Duration _backoff(int retries) =>
    Duration(milliseconds: _baseBackoffMs * (1 << retries));

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

// ============================================================================
// Public API
// ============================================================================

/// Enqueue a retriable API call.
///
/// [label] is a human-readable name used for debug output.
/// [fn] is the async function to execute (closure capturing the request payload).
/// [maxRetries] overrides the default max retries (default: 3).
void enqueue(
  String label,
  Future<void> Function() fn, {
  int maxRetries = _maxRetries,
}) {
  final item = _QueueItem(
    id: '${DateTime.now().millisecondsSinceEpoch}-${_generateId()}',
    fn: fn,
    label: label,
    maxRetries: maxRetries,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
  _queue.add(item);
  _persistQueue();
}

String _generateId() {
  // Simple random suffix for queue item IDs
  final rand = DateTime.now().microsecondsSinceEpoch % 1000000;
  return rand.toRadixString(36);
}

/// Attempt to flush all queued requests in order.
/// Successful items are removed. Failed items have their retry count incremented.
/// Items that exceed maxRetries are dropped.
Future<void> flush() async {
  if (_queue.isEmpty || _isFlushing) return;
  _isFlushing = true;

  // Work on a snapshot to avoid mutation issues during iteration
  final snapshot = List<_QueueItem>.from(_queue);

  for (final item in snapshot) {
    try {
      await item.fn();
      _queue.removeWhere((q) => q.id == item.id);
      await _removeFromPersisted(item.id);
    } catch (err) {
      if (_isClientError(err)) {
        _queue.removeWhere((q) => q.id == item.id);
        await _removeFromPersisted(item.id);
        // ignore: avoid_print
        print(
          '[Encatch] Retry queue: dropping "${item.label}" (client error, no retry): $err',
        );
      } else {
        item.retries += 1;
        if (item.retries >= item.maxRetries) {
          _queue.removeWhere((q) => q.id == item.id);
          await _removeFromPersisted(item.id);
          // ignore: avoid_print
          print(
            '[Encatch] Retry queue: dropping "${item.label}" after ${item.maxRetries} retries: $err',
          );
        } else {
          final delay = _backoff(item.retries);
          await _persistQueue();
          Timer(delay, () => _flushSingle(item.id));
        }
      }
    }
  }

  _isFlushing = false;
}

Future<void> _flushSingle(String id) async {
  final item = _queue.cast<_QueueItem?>().firstWhere(
    (q) => q?.id == id,
    orElse: () => null,
  );
  if (item == null) return;

  try {
    await item.fn();
    _queue.removeWhere((q) => q.id == id);
    await _removeFromPersisted(id);
  } catch (err) {
    if (_isClientError(err)) {
      _queue.removeWhere((q) => q.id == id);
      await _removeFromPersisted(id);
      // ignore: avoid_print
      print(
        '[Encatch] Retry queue: dropping "${item.label}" (client error, no retry): $err',
      );
      return;
    }
    item.retries += 1;
    if (item.retries >= item.maxRetries) {
      _queue.removeWhere((q) => q.id == id);
      await _removeFromPersisted(id);
      // ignore: avoid_print
      print(
        '[Encatch] Retry queue: dropping "${item.label}" after ${item.maxRetries} retries: $err',
      );
    } else {
      final delay = _backoff(item.retries);
      await _persistQueue();
      Timer(delay, () => _flushSingle(id));
    }
  }
}

/// Returns the current number of items in the in-memory queue.
int queueSize() => _queue.length;

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
