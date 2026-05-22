/// EncatchProvider — top-level widget for Encatch Flutter SDK initialization.
/// Mirrors EncatchProvider.tsx from the React Native SDK.
///
/// Wrap your app's root widget with EncatchProvider to:
///  - Initialize the SDK with your API key
///  - Start a session automatically
///  - Mount the headless EncatchWebView listener
///
/// The form overlay is shown via Flutter's Overlay system (OverlayEntry),
/// inserting above the root Navigator. This requires zero additional setup —
/// no navigatorKey, no SDK conflicts with Sentry, GetX, or other packages.
///
/// Also exports EncatchNavigatorObserver for optional automatic screen tracking.
library;

import 'package:flutter/material.dart';
import 'encatch.dart';
import 'encatch_webview.dart';
import 'types.dart';

// ============================================================================
// EncatchProvider
// ============================================================================

/// Top-level widget that initializes the Encatch Flutter SDK.
///
/// Wrap your app's root widget with [EncatchProvider] to initialize the SDK,
/// start a session, and mount the headless WebView form listener.
///
/// ```dart
/// void main() {
///   runApp(
///     EncatchProvider(
///       apiKey: 'your-api-key',
///       child: MyApp(),
///     ),
///   );
/// }
/// ```
class EncatchProvider extends StatefulWidget {
  /// The root widget of your app.
  final Widget child;

  /// Your Encatch API key.
  final String apiKey;

  /// Optional SDK configuration.
  final EncatchConfig? config;

  const EncatchProvider({
    required this.child,
    required this.apiKey,
    this.config,
    super.key,
  });

  @override
  State<EncatchProvider> createState() => _EncatchProviderState();
}

class _EncatchProviderState extends State<EncatchProvider> {
  bool _initStarted = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_initStarted) return;
    _initStarted = true;
    await Encatch.init(widget.apiKey, config: widget.config);
    // Start a session for anonymous users immediately after init, mirroring the
    // React Native SDK behaviour. identifyUser() will start its own session
    // (with skipImmediatePing + skipImmediateTrackScreen) and take over.
    if (!Encatch.isFullScreen) {
      await Encatch.startSession();
    }
  }

  @override
  void dispose() {
    Encatch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // EncatchWebView is headless — it renders nothing itself.
    // The form overlay is pushed as a full-screen route via Encatch.navigatorKey.
    // Wrap in Directionality so the SDK works even when placed above MaterialApp
    // (which is the typical setup when EncatchProvider wraps the whole app).
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(children: [widget.child, const EncatchWebView()]),
    );
  }
}

// ============================================================================
// EncatchNavigatorObserver — optional automatic screen tracking
// ============================================================================

/// Add to MaterialApp.navigatorObservers for automatic screen tracking.
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [EncatchNavigatorObserver()],
///   // ...
/// )
/// ```
class EncatchNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _trackRoute(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _trackRoute(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _trackRoute(previousRoute);
  }

  void _trackRoute(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && name.isNotEmpty && name != '/') {
      Encatch.trackScreen(name).catchError((_) {});
    }
  }
}
