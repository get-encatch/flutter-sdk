/// Device information helpers for the Encatch Flutter SDK.
/// Mirrors device-info.ts from the React Native SDK.
/// Uses device_info_plus, package_info_plus, and dart:io.
library;

import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _deviceInfoPlugin = DeviceInfoPlugin();

// ============================================================================
// Locale
// ============================================================================

/// Returns the device's primary locale tag (e.g. 'en-US', 'fr-FR').
String getDeviceLocale() {
  try {
    // Platform.localeName returns e.g. 'en_US' — convert underscore to hyphen
    final locale = Platform.localeName;
    if (locale.isNotEmpty) {
      return locale.replaceAll('_', '-');
    }
  } catch (_) {
    // ignore
  }
  return 'en';
}

// ============================================================================
// Device Type
// ============================================================================

/// Returns the device type: 'mobile', 'tablet', or 'desktop'.
Future<String> getDeviceType() async {
  try {
    if (Platform.isAndroid) {
      // Android doesn't expose tablet directly; fall through to default 'mobile'.
    } else if (Platform.isIOS) {
      final info = await _deviceInfoPlugin.iosInfo;
      // iPad models start with "iPad"
      if (info.model.toLowerCase().contains('ipad')) {
        return 'tablet';
      }
      return 'mobile';
    } else if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      return 'desktop';
    }
  } catch (_) {
    // ignore — fall through to default
  }
  return 'mobile';
}

// ============================================================================
// OS Version
// ============================================================================

/// Returns the OS version string.
Future<String> getOsVersion() async {
  try {
    if (Platform.isAndroid) {
      final info = await _deviceInfoPlugin.androidInfo;
      return info.version.release;
    } else if (Platform.isIOS) {
      final info = await _deviceInfoPlugin.iosInfo;
      return info.systemVersion;
    } else if (Platform.isMacOS) {
      final info = await _deviceInfoPlugin.macOsInfo;
      return '${info.majorVersion}.${info.minorVersion}.${info.patchVersion}';
    }
  } catch (_) {
    // ignore
  }
  return Platform.operatingSystemVersion;
}

// ============================================================================
// App Version
// ============================================================================

/// Returns the native app version (e.g. "2.11.0").
Future<String?> getAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) return info.version;
  } catch (_) {
    // ignore
  }
  return null;
}

// ============================================================================
// App Package / Bundle ID
// ============================================================================

/// Returns the host app's package name (Android) or bundle ID (iOS).
/// Used as Referer header in API requests to identify the installing app.
Future<String?> getAppPackageId() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.packageName.isNotEmpty) return info.packageName;
  } catch (_) {
    // ignore
  }
  return null;
}

// ============================================================================
// Timezone
// ============================================================================

/// Returns the device timezone (e.g. 'Asia/Kolkata', 'America/New_York').
String? getTimezone() {
  try {
    return DateTime.now().timeZoneName;
  } catch (_) {
    return null;
  }
}

// ============================================================================
// Platform
// ============================================================================

/// Returns 'ios', 'android', or 'web'.
String getPlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

// ============================================================================
// Device Type Env (native vs web)
// ============================================================================

/// Returns 'native' (iOS/Android) or 'web'.
/// Used for $deviceType in API requests.
String getDeviceTypeEnv() {
  return kIsWeb ? 'web' : 'native';
}
