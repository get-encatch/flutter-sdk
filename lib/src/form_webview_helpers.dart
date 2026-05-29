/// Shared helpers used by both EncatchWebView (modal) and EncatchInlineForm (inline).
/// Mirrors form-webview-helpers.ts from the React Native SDK.
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'types.dart';

// ============================================================================
// URL builder
// ============================================================================

/// Builds the WebView source URL for the flutter-sdk-form page.
///
/// [instanceKey] is incremented on each new form load to bust the WebView
/// cache between form loads — the same mechanism as RN's webViewInstanceKey.
/// Pass [FormPresentation.inline] to add `presentation=inline` so the web
/// page applies inline CSS instead of viewport-sized overlay styles.
String buildFormWebViewUrl({
  required String webHost,
  required String formId,
  required int instanceKey,
  required bool debugMode,
  FormPresentation presentation = FormPresentation.modal,
}) {
  final params = <String, String>{
    'formId': formId,
    'ts': instanceKey.toString(),
  };
  if (debugMode) params['debug'] = 'true';
  if (presentation == FormPresentation.inline) {
    params['presentation'] = 'inline';
  }
  final query = params.entries
      .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
      .join('&');
  return '$webHost/s/flutter-sdk-form?$query';
}

// ============================================================================
// Color helpers (used by skeleton and WebView background)
// ============================================================================

/// Extracts `--background` (falling back to `--popover`) from the
/// shadcn-variables JSON string stored in `themes[mode].theme` and returns it
/// as a Flutter [Color].
Color getBackgroundColor(
  dynamic themeJson,
  Color fallback, {
  String debugLabel = 'EncatchWebView',
}) {
  if (themeJson == null || themeJson == '{}') {
    _debugPrintBackgroundColor(
      debugLabel: debugLabel,
      rawBackground: null,
      rawPopover: null,
      selectedToken: null,
      selectedValue: null,
      fallback: fallback,
      resolved: fallback,
      reason: 'empty theme',
    );
    return fallback;
  }
  try {
    final vars = jsonDecode(themeJson as String) as Map<String, dynamic>;
    final rawBackground = vars['--background'];
    final rawPopover = vars['--popover'];
    final selectedToken = rawBackground != null ? '--background' : '--popover';
    final value = rawBackground ?? rawPopover;
    final parsedColor =
        value is String && value.isNotEmpty ? _tryParseColor(value) : null;
    final resolved = parsedColor ?? fallback;
    _debugPrintBackgroundColor(
      debugLabel: debugLabel,
      rawBackground: rawBackground,
      rawPopover: rawPopover,
      selectedToken: selectedToken,
      selectedValue: value,
      fallback: fallback,
      resolved: resolved,
      reason: parsedColor != null ? 'parsed' : 'fallback',
    );
    return resolved;
  } catch (e) {
    _debugPrintBackgroundColor(
      debugLabel: debugLabel,
      rawBackground: null,
      rawPopover: null,
      selectedToken: null,
      selectedValue: null,
      fallback: fallback,
      resolved: fallback,
      reason: 'invalid theme JSON: $e',
    );
  }
  return fallback;
}

/// Resolved WebView/skeleton colors — mirrors RN `popupBgColor` / `activeMode`.
class FormWebViewTheme {
  final Color backgroundColor;
  final Brightness activeMode;

  const FormWebViewTheme({
    required this.backgroundColor,
    required this.activeMode,
  });
}

String? encatchThemeToModeString(EncatchTheme? theme) {
  if (theme == null) return null;
  switch (theme) {
    case EncatchTheme.light:
      return 'light';
    case EncatchTheme.dark:
      return 'dark';
    case EncatchTheme.system:
      return 'system';
  }
}

/// Resolves which theme mode ("light" | "dark") is active for the form.
/// Respects the form's shareableMode setting first, then falls back to
/// the device's system brightness.
Brightness resolveActiveMode({
  required String? shareableMode,
  required Brightness systemBrightness,
}) {
  if (shareableMode == 'light') return Brightness.light;
  if (shareableMode == 'dark') return Brightness.dark;
  return systemBrightness;
}

/// Resolves WebView background and skeleton row mode from a [ShowFormPayload].
///
/// Prefers [ShowFormPayload.theme] (Encatch SDK theme), then form
/// `shareableMode`, then [systemBrightness] — matching RN EncatchWebView /
/// EncatchInlineForm.
FormWebViewTheme resolveFormWebViewTheme(
  ShowFormPayload? payload, {
  required Brightness systemBrightness,
  String debugLabel = 'EncatchWebView',
}) {
  if (payload == null) {
    return FormWebViewTheme(
      backgroundColor: Colors.white,
      activeMode: systemBrightness,
    );
  }

  final appearance = payload.formConfig.appearanceProperties;
  final payloadTheme = encatchThemeToModeString(payload.theme);
  final shareableMode =
      appearance?['featureSettings']?['shareableMode'] as String?;
  final effectiveMode = payloadTheme ?? shareableMode;
  final activeMode = resolveActiveMode(
    shareableMode: effectiveMode,
    systemBrightness: systemBrightness,
  );
  final activeModeKey = activeMode == Brightness.dark ? 'dark' : 'light';
  final themeJson = appearance?['themes']?[activeModeKey]?['theme'];
  final fallback =
      activeMode == Brightness.dark ? const Color(0xFF1a1a1a) : Colors.white;

  return FormWebViewTheme(
    backgroundColor: getBackgroundColor(themeJson, fallback, debugLabel: debugLabel),
    activeMode: activeMode,
  );
}

/// Resolves the WebView/skeleton background color from a [ShowFormPayload].
Color resolveBackgroundColor(
  ShowFormPayload? payload, {
  required Brightness systemBrightness,
  String debugLabel = 'EncatchWebView',
}) {
  return resolveFormWebViewTheme(
    payload,
    systemBrightness: systemBrightness,
    debugLabel: debugLabel,
  ).backgroundColor;
}

// ============================================================================
// Native color parser
// ============================================================================

Color? _tryParseColor(String value, {double opacity = 1.0}) {
  final trimmed = value.trim();
  final rgbColor = _tryParseRgbColor(trimmed);
  if (rgbColor != null) return rgbColor;

  var h = trimmed.replaceAll('#', '');
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 8) {
    final a = int.tryParse(h.substring(0, 2), radix: 16) ?? 0;
    final r = int.tryParse(h.substring(2, 4), radix: 16) ?? 0;
    final g = int.tryParse(h.substring(4, 6), radix: 16) ?? 0;
    final b = int.tryParse(h.substring(6, 8), radix: 16) ?? 0;
    return Color.fromARGB(a, r, g, b);
  }
  if (h.length == 6) {
    final r = int.tryParse(h.substring(0, 2), radix: 16) ?? 0;
    final g = int.tryParse(h.substring(2, 4), radix: 16) ?? 0;
    final b = int.tryParse(h.substring(4, 6), radix: 16) ?? 0;
    return Color.fromARGB((opacity * 255).round(), r, g, b);
  }
  return null;
}

Color? _tryParseRgbColor(String value) {
  final match = RegExp(
    r'^rgba?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)(?:\s*,\s*([0-9.]+%?))?\s*\)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;

  final r = _parseRgbChannel(match.group(1));
  final g = _parseRgbChannel(match.group(2));
  final b = _parseRgbChannel(match.group(3));
  final a = _parseAlphaChannel(match.group(4));
  if (r == null || g == null || b == null || a == null) return null;

  return Color.fromARGB(a, r, g, b);
}

int? _parseRgbChannel(String? raw) {
  final value = double.tryParse(raw ?? '');
  if (value == null) return null;
  return value.round().clamp(0, 255);
}

int? _parseAlphaChannel(String? raw) {
  if (raw == null || raw.trim().isEmpty) return 255;
  final value = raw.trim();
  if (value.endsWith('%')) {
    final percent = double.tryParse(value.substring(0, value.length - 1));
    if (percent == null) return null;
    return ((percent.clamp(0, 100) / 100) * 255).round();
  }
  final alpha = double.tryParse(value);
  if (alpha == null) return null;
  return (alpha.clamp(0, 1) * 255).round();
}

void _debugPrintBackgroundColor({
  required String debugLabel,
  required dynamic rawBackground,
  required dynamic rawPopover,
  required String? selectedToken,
  required dynamic selectedValue,
  required Color fallback,
  required Color resolved,
  required String reason,
}) {
  assert(() {
    final selected = selectedValue?.toString();
    final isOklch = selected?.trimLeft().startsWith('oklch(') ?? false;
    debugPrint(
      '[$debugLabel] backgroundColor resolved '
      'selectedToken=$selectedToken '
      'selectedValue=$selectedValue '
      'rawBackground=$rawBackground '
      'rawPopover=$rawPopover '
      'isOklch=$isOklch '
      'fallback=$fallback '
      'resolved=$resolved '
      'reason=$reason',
    );
    return true;
  }());
}
