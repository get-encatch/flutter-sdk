/// SharedPreferences-backed persistence layer for the Encatch Flutter SDK.
/// Mirrors storage.ts from the React Native SDK.
/// Session ID is in-memory only — reset when the app process ends.
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'types.dart';

// ============================================================================
// Storage Keys
// ============================================================================

const _keyDeviceId = 'encatch_device_id';
const _keyUserName = 'encatch_user_name';
const _keyUserIdPrefix = 'encatch_user_id_';
const _keyFtPrefix = 'encatch_ft_';
const _keyPreferences = 'encatch_preferences';
const _keyRetryQueue = 'encatch_retry_queue';
const _keySessionStopped = 'encatch_session_stopped';

// Exposed so retry_queue.dart can reference it
const storageKeyRetryQueue = _keyRetryQueue;

const _uuid = Uuid();

// ============================================================================
// Device ID
// ============================================================================

/// Returns the persisted device ID, creating and storing one if it doesn't exist.
/// Uses UUIDv7 (time-ordered). Device IDs survive app restarts; reinstall clears.
Future<String> getOrCreateDeviceId() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_keyDeviceId);
    if (stored != null && stored.isNotEmpty) return stored;
    final id = _uuid.v7();
    await prefs.setString(_keyDeviceId, id);
    return id;
  } catch (_) {
    return _uuid.v7();
  }
}

// ============================================================================
// Session ID (in-memory only — reset when app process ends)
// ============================================================================

String? _inMemorySessionId;

/// Returns the current session ID. Creates a new one if none exists.
/// Session is in-memory only: reset when the app process ends.
Future<String> getOrCreateSessionId() async {
  _inMemorySessionId ??= _uuid.v7();
  return _inMemorySessionId!;
}

/// Clears the current session, forcing a new one on next call.
Future<void> clearSession() async {
  _inMemorySessionId = null;
}

// ============================================================================
// User Name
// ============================================================================

Future<String?> getUserName() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserName);
  } catch (_) {
    return null;
  }
}

Future<void> setUserName(String name) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUserName, name);
  } catch (_) {
    // ignore storage failures
  }
}

Future<void> clearUserName() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUserName);
  } catch (_) {
    // ignore
  }
}

// ============================================================================
// User ID (keyed by userName, mirrors web SDK's localStorage pattern)
// ============================================================================

Future<String?> getUserId(String userName) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_keyUserIdPrefix$userName');
  } catch (_) {
    return null;
  }
}

Future<void> setUserId(String userName, String userId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_keyUserIdPrefix$userName', userId);
  } catch (_) {
    // ignore
  }
}

Future<void> clearUserId(String userName) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_keyUserIdPrefix$userName');
  } catch (_) {
    // ignore
  }
}

// ============================================================================
// Feedback Transactions
// Keyed by identity key ('anonymous' or userName) — persisted across sessions.
// ============================================================================

String _ftKey(String identityKey) => '$_keyFtPrefix$identityKey';

Future<String?> getFeedbackTransactions(String identityKey) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ftKey(identityKey));
  } catch (_) {
    return null;
  }
}

Future<void> setFeedbackTransactions(String identityKey, String value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ftKey(identityKey), value);
  } catch (_) {
    // ignore
  }
}

Future<void> clearFeedbackTransactions(String identityKey) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_ftKey(identityKey));
  } catch (_) {
    // ignore
  }
}

// ============================================================================
// Preferences (locale / country — persisted across restarts)
// ============================================================================

Future<Preferences> getPreferences() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyPreferences);
    if (raw == null) return const Preferences();
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return Preferences.fromJson(map);
  } catch (_) {
    return const Preferences();
  }
}

Future<void> setPreferences(Preferences updates) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final current = await getPreferences();
    final merged = Preferences(
      locale: updates.locale ?? current.locale,
      country: updates.country ?? current.country,
    );
    await prefs.setString(_keyPreferences, jsonEncode(merged.toJson()));
  } catch (_) {
    // ignore
  }
}

Future<void> clearPreferences() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPreferences);
  } catch (_) {
    // ignore
  }
}

// ============================================================================
// Session stopped flag (persisted — survives app restarts)
// Written by stopSession(); cleared by startSession().
// ============================================================================

Future<bool> getSessionStopped() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keySessionStopped) ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> setSessionStopped() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySessionStopped, true);
  } catch (_) {
    // ignore
  }
}

Future<void> clearSessionStopped() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySessionStopped);
  } catch (_) {
    // ignore
  }
}
