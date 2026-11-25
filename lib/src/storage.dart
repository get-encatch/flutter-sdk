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
const _keyUserSignaturePrefix = 'encatch_user_signature_';
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
// Where user data lives: the device (default) or memory only
// (EncatchConfig.persistUserAcrossRestarts false). User data is the user name,
// user ids, secure signatures and survey history (feedback transactions).
// ============================================================================

bool _persistUser = true;
final _memoryUserStore = <String, String>{};

bool _isUserKey(String key) =>
    key == _keyUserName ||
    key.startsWith(_keyUserIdPrefix) ||
    key.startsWith(_keyUserSignaturePrefix) ||
    key.startsWith(_keyFtPrefix);

/// true saves user data on the device, to be restored at the next launch;
/// false keeps it in memory for this app run only.
void setPersistUserAcrossRestarts(bool enabled) {
  _persistUser = enabled;
}

/// Forgets the user data kept in memory (persistUserAcrossRestarts false).
void clearMemoryUserData() => _memoryUserStore.clear();

/// Deletes every piece of user data saved on the device, by an earlier run
/// with persistUserAcrossRestarts true. The device id, the preferences and a
/// saved stop stay.
Future<void> clearStoredUserData() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where(_isUserKey).toList()) {
      await prefs.remove(key);
    }
  } catch (_) {
    // ignore
  }
}

Future<String?> _readUserData(String key) async {
  if (!_persistUser) return _memoryUserStore[key];
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(key);
}

Future<void> _writeUserData(String key, String value) async {
  if (!_persistUser) {
    _memoryUserStore[key] = value;
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, value);
}

Future<void> _removeUserData(String key) async {
  if (!_persistUser) {
    _memoryUserStore.remove(key);
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(key);
}

// ============================================================================
// User Name
// ============================================================================

Future<String?> getUserName() async {
  try {
    return await _readUserData(_keyUserName);
  } catch (_) {
    return null;
  }
}

Future<void> setUserName(String name) async {
  try {
    await _writeUserData(_keyUserName, name);
  } catch (_) {
    // ignore storage failures
  }
}

Future<void> clearUserName() async {
  try {
    await _removeUserData(_keyUserName);
  } catch (_) {
    // ignore
  }
}

// ============================================================================
// User ID (keyed by userName, mirrors web SDK's localStorage pattern)
// ============================================================================

Future<String?> getUserId(String userName) async {
  try {
    return await _readUserData('$_keyUserIdPrefix$userName');
  } catch (_) {
    return null;
  }
}

Future<void> setUserId(String userName, String userId) async {
  try {
    await _writeUserData('$_keyUserIdPrefix$userName', userId);
  } catch (_) {
    // ignore
  }
}

Future<void> clearUserId(String userName) async {
  try {
    await _removeUserData('$_keyUserIdPrefix$userName');
  } catch (_) {
    // ignore
  }
}

// ============================================================================
// User signature (secure mode), keyed by userName like the user id
// ============================================================================

/// The signature saved after a successful secure identify, with the time it
/// was signed for keys that have a session time.
Future<({String signature, String? time})?> getUserSignature(
  String userName,
) async {
  try {
    final raw = await _readUserData('$_keyUserSignaturePrefix$userName');
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final signature = map['signature'] as String?;
    if (signature == null || signature.isEmpty) return null;
    return (signature: signature, time: map['time'] as String?);
  } catch (_) {
    return null;
  }
}

Future<void> setUserSignature(
  String userName,
  String signature,
  String? time,
) async {
  try {
    await _writeUserData(
      '$_keyUserSignaturePrefix$userName',
      jsonEncode({'signature': signature, 'time': ?time}),
    );
  } catch (_) {
    // ignore
  }
}

Future<void> clearUserSignature(String userName) async {
  try {
    await _removeUserData('$_keyUserSignaturePrefix$userName');
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
    return await _readUserData(_ftKey(identityKey));
  } catch (_) {
    return null;
  }
}

Future<void> setFeedbackTransactions(String identityKey, String value) async {
  try {
    await _writeUserData(_ftKey(identityKey), value);
  } catch (_) {
    // ignore
  }
}

Future<void> clearFeedbackTransactions(String identityKey) async {
  try {
    await _removeUserData(_ftKey(identityKey));
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
