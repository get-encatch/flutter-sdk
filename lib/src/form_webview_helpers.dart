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
      .map(
        (e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
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
    final parsedColor = value is String && value.isNotEmpty
        ? _tryParseColor(value)
        : null;
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
  final fallback = activeMode == Brightness.dark
      ? const Color(0xFF1a1a1a)
      : Colors.white;

  return FormWebViewTheme(
    backgroundColor: getBackgroundColor(
      themeJson,
      fallback,
      debugLabel: debugLabel,
    ),
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
// Corner / layout helpers (modal + inline) — mirrors RN form-webview-helpers.ts
// ============================================================================

/// Corner roundness preset — matches web-form-engine-core and iframe-manager.
enum CornerStyle { sharp, soft, round }

/// Maps corners preset to logical pixels (16px = 1rem), aligned with App.svelte.
double resolveCornerRadiusPx(CornerStyle corners) {
  switch (corners) {
    case CornerStyle.sharp:
      return 2;
    case CornerStyle.round:
      return 24;
    case CornerStyle.soft:
      return 10;
  }
}

/// Reads appearance.appearance.corners with legacy featureSettings.corners fallback.
CornerStyle resolveCornersFromFormConfig(
  Map<String, dynamic>? appearanceProperties,
) {
  final appearance =
      appearanceProperties?['appearance'] as Map<String, dynamic>?;
  final featureSettings =
      appearanceProperties?['featureSettings'] as Map<String, dynamic>?;
  final value =
      appearance?['corners'] as String? ??
      featureSettings?['corners'] as String?;
  switch (value) {
    case 'sharp':
      return CornerStyle.sharp;
    case 'round':
      return CornerStyle.round;
    default:
      return CornerStyle.soft;
  }
}

/// Per-corner radii for the modal shell. Screen-touching edges stay square (0).
BorderRadius getBorderRadii(
  String position, {
  CornerStyle corners = CornerStyle.soft,
}) {
  if (position == 'full-center' || position == 'full') {
    return BorderRadius.zero;
  }

  final radius = Radius.circular(resolveCornerRadiusPx(corners));
  final touchesTop = position.contains('top');
  final touchesBottom = position.contains('bottom');
  final touchesLeft = position.endsWith('left');
  final touchesRight = position.endsWith('right');

  return BorderRadius.only(
    topLeft: touchesTop || touchesLeft ? Radius.zero : radius,
    topRight: touchesTop || touchesRight ? Radius.zero : radius,
    bottomLeft: touchesBottom || touchesLeft ? Radius.zero : radius,
    bottomRight: touchesBottom || touchesRight ? Radius.zero : radius,
  );
}

/// Uniform radii for inline embeds — matches web-sdk iframe-manager inline shell.
BorderRadius getInlineBorderRadii({CornerStyle corners = CornerStyle.soft}) {
  return BorderRadius.circular(resolveCornerRadiusPx(corners));
}

/// In-app content width preset — matches web-form-engine-core and iframe-manager.
enum InAppSize { compact, standard, spacious }

/// Matches iframe-manager mobile breakpoint (window.innerWidth < 600).
const int inAppMobileBreakpointPx = 600;

/// Reads inApp.size with legacy featureSettings.inAppSize fallback.
InAppSize resolveInAppSizeFromFormConfig(
  Map<String, dynamic>? appearanceProperties,
) {
  final inApp = appearanceProperties?['inApp'] as Map<String, dynamic>?;
  final featureSettings =
      appearanceProperties?['featureSettings'] as Map<String, dynamic>?;
  final value =
      inApp?['size'] as String? ?? featureSettings?['inAppSize'] as String?;
  switch (value) {
    case 'compact':
      return InAppSize.compact;
    case 'spacious':
      return InAppSize.spacious;
    default:
      return InAppSize.standard;
  }
}

/// Reads inApp.position with legacy selectedPosition fallback.
String resolveSelectedPositionFromFormConfig(
  Map<String, dynamic>? appearanceProperties,
) {
  final inApp = appearanceProperties?['inApp'] as Map<String, dynamic>?;
  return (inApp?['position'] as String?) ??
      (appearanceProperties?['selectedPosition'] as String?) ??
      'middle-center';
}

bool isMobileLayout(double screenWidth) =>
    screenWidth < inAppMobileBreakpointPx;

/// Collapse left/right anchors to center on mobile — matches iframe-manager.
String normalizePosition(String position, double screenWidth) {
  if (position == 'full-center' || position == 'full') return 'full-center';
  if (!isMobileLayout(screenWidth)) return position;
  if (position.startsWith('top')) return 'top-center';
  if (position.startsWith('bottom')) return 'bottom-center';
  return 'middle-center';
}

bool isCenterAlignedPosition(String position) =>
    position.endsWith('-center') || position == 'center';

/// Popup shell max-width — aligned with iframe-manager getInAppMaxWidth().
double resolveInAppMaxWidthPx(
  InAppSize size,
  String position,
  double screenWidth, {
  double horizontalInsetPx = 0,
}) {
  final available = (screenWidth - horizontalInsetPx * 2).clamp(
    100.0,
    double.infinity,
  );
  if (position == 'full-center') return available;

  final centered = isCenterAlignedPosition(position);
  final presetWidth = centered
      ? switch (size) {
          InAppSize.compact => 480.0,
          InAppSize.spacious => 720.0,
          InAppSize.standard => 600.0,
        }
      : switch (size) {
          InAppSize.compact => 320.0,
          InAppSize.spacious => 500.0,
          InAppSize.standard => 400.0,
        };

  return presetWidth < available ? presetWidth : available;
}

/// Reads inApp.maxHeightPercent with legacy featureSettings.maxDialogHeightPercentInApp fallback.
double resolveMaxHeightFractionFromFormConfig(
  Map<String, dynamic>? appearanceProperties,
) {
  final inApp = appearanceProperties?['inApp'] as Map<String, dynamic>?;
  final featureSettings =
      appearanceProperties?['featureSettings'] as Map<String, dynamic>?;
  final raw =
      inApp?['maxHeightPercent'] ??
      featureSettings?['maxDialogHeightPercentInApp'];
  if (raw is num) return (raw.toDouble() / 100.0).clamp(0.1, 1.0);
  return 0.8;
}

/// Modal shell max-height — aligned with iframe-manager and RN EncatchWebView.
/// Height is capped by viewport × maxHeightPercent only (inAppSize affects width, not height).
double resolveMaxDialogHeightPx({
  required String position,
  required double usableHeightPx,
  required double maxHeightFraction,
  bool keyboardVisible = false,
  bool useTallMaxHeight = false,
}) {
  if (position == 'full-center') return usableHeightPx;
  if (keyboardVisible || useTallMaxHeight) return usableHeightPx * 0.95;
  return usableHeightPx * maxHeightFraction;
}

/// Modal popup drop shadow — mirrors RN getModalPopupShadowStyle().
///
/// Must be applied to an outer, unclipped shell around the popup card (the
/// rounded-corner content itself is rendered in a separate `ClipRRect`,
/// since clipping a widget also clips away any shadow drawn on it).
/// Not used for the full-center position, matching RN's behavior.
List<BoxShadow> getModalPopupShadowStyle() {
  return [
    BoxShadow(
      color: Color.fromARGB((0.3 * 255).round(), 0, 0, 0),
      offset: const Offset(0, 20),
      blurRadius: 60,
    ),
  ];
}

typedef PositionAlignment = ({
  MainAxisAlignment main,
  CrossAxisAlignment cross,
});

/// Flexbox alignment for modal position — matches RN getPositionLayout().
PositionAlignment getPositionAlignment(String position) {
  var main = MainAxisAlignment.center;
  var cross = CrossAxisAlignment.center;

  if (position.startsWith('top')) {
    main = MainAxisAlignment.start;
  } else if (position.startsWith('bottom')) {
    main = MainAxisAlignment.end;
  }

  if (position.endsWith('left')) {
    cross = CrossAxisAlignment.start;
  } else if (position.endsWith('right')) {
    cross = CrossAxisAlignment.end;
  }

  return (main: main, cross: cross);
}

// ============================================================================
// Modal overlay / darkOverlay — mirrors RN form-webview-helpers.ts
// ============================================================================

const Color _defaultOverlayColor = Color.fromARGB(
  128,
  0,
  0,
  0,
); // rgba(0,0,0,0.5)
const double _overlayFallbackAlpha = 0.4;

/// Reads inApp.darkOverlay with legacy featureSettings.darkOverlay fallback.
bool resolveDarkOverlayFromFormConfig(
  Map<String, dynamic>? appearanceProperties,
) {
  final inApp = appearanceProperties?['inApp'] as Map<String, dynamic>?;
  final featureSettings =
      appearanceProperties?['featureSettings'] as Map<String, dynamic>?;
  return (inApp?['darkOverlay'] ?? featureSettings?['darkOverlay']) == true;
}

/// Overlay base color from theme JSON — aligned with shareable encatch.ts.
String getOverlayColorFromTheme(Map<String, dynamic>? themeConfig) {
  if (themeConfig == null) return 'rgba(0, 0, 0, 0.5)';

  final overlayColor = themeConfig['overlayColor'];
  if (overlayColor is String && overlayColor.isNotEmpty) {
    return overlayColor;
  }

  final themeJson = themeConfig['theme'];
  if (themeJson == null || themeJson == '{}' || themeJson == '') {
    return 'rgba(0, 0, 0, 0.5)';
  }

  try {
    final vars = jsonDecode(themeJson as String) as Map<String, dynamic>;
    final color =
        vars['overlayColor'] ??
        vars['--encatch-overlay-color'] ??
        vars['--overlay'] ??
        vars['--popover'];
    if (color is String && color.isNotEmpty) return color;
  } catch (_) {
    // fall through
  }
  return 'rgba(0, 0, 0, 0.5)';
}

/// Parses overlay color strings into [Color], preserving explicit alpha when set.
Color? parseOverlayColorWithAlpha(
  String color, {
  double fallbackAlpha = _overlayFallbackAlpha,
}) {
  final parsed = _tryParseRgbColor(color.trim());
  if (parsed != null) return parsed;

  final rgbOnly = RegExp(
    r'^rgb\s*\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)$',
    caseSensitive: false,
  ).firstMatch(color.trim());
  if (rgbOnly != null) {
    final r = _parseRgbChannel(rgbOnly.group(1));
    final g = _parseRgbChannel(rgbOnly.group(2));
    final b = _parseRgbChannel(rgbOnly.group(3));
    if (r != null && g != null && b != null) {
      return Color.fromARGB((_overlayFallbackAlpha * 255).round(), r, g, b);
    }
  }

  return _tryParseColor(color, opacity: fallbackAlpha);
}

/// Modal backdrop color when darkOverlay is enabled; transparent when disabled.
Color resolveModalOverlayBackgroundColor({
  required Map<String, dynamic>? appearanceProperties,
  required Brightness activeMode,
  required bool darkOverlay,
}) {
  if (!darkOverlay) return Colors.transparent;

  final themes = appearanceProperties?['themes'] as Map<String, dynamic>?;
  final modeKey = activeMode == Brightness.dark ? 'dark' : 'light';
  final themeConfig = themes?[modeKey] as Map<String, dynamic>?;
  final base = getOverlayColorFromTheme(themeConfig);
  return parseOverlayColorWithAlpha(base) ?? _defaultOverlayColor;
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
