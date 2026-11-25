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

import 'package:flutter/widgets.dart';
import 'encatch.dart';
import 'encatch_webview.dart';
import 'internals.dart' as internals;
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

  /// Whether the session starts by itself for a visitor (a user who is not
  /// identified). Defaults to true.
  ///
  /// - true: every launch starts the background ping and
  ///   [EncatchNavigatorObserver]'s automatic screen tracking, for visitors
  ///   too.
  /// - false: a visitor gets no ping and no automatic screen tracking. The
  ///   session starts when [Encatch.identifyUser] succeeds (the current screen
  ///   is then sent once) or when the app calls [Encatch.startSession], and
  ///   stops again on [Encatch.resetUser]. A user restored from the device at
  ///   launch starts as usual.
  ///
  /// Calls the app makes itself ([Encatch.trackScreen], [Encatch.trackEvent],
  /// [Encatch.showForm] and submits) are always sent. With false, surveys set
  /// to show immediately, after a delay or on a page visit cannot reach
  /// visitors, because they arrive in ping and screen replies.
  ///
  /// Read at launch and on [Encatch.resetUser]; a change while the app runs
  /// applies from then.
  final bool autoStartVisitorSession;

  const EncatchProvider({
    required this.child,
    required this.apiKey,
    this.config,
    this.autoStartVisitorSession = true,
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
    // Before init, so the launch sees it.
    internals.autoStartVisitorSession = widget.autoStartVisitorSession;
    await Encatch.init(widget.apiKey, config: widget.config);
    // Start the session at launch, for visitors too. identifyUser() starts
    // its own session (with skipImmediatePing + skipImmediateTrackScreen) and
    // takes over. Not started when the app stopped the session in an earlier
    // run (until it calls Encatch.startSession() or identifies a user), or
    // for a visitor when autoStartVisitorSession is false.
    await internals.startSessionOnLaunch?.call();
  }

  @override
  void didUpdateWidget(EncatchProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Applies from the next resetUser() or launch.
    internals.autoStartVisitorSession = widget.autoStartVisitorSession;
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
  /// The last named route this observer saw, tracked or not (`/` is seen but
  /// not tracked by default). A route is tracked only when its name differs
  /// from this, so closing a dialog or another unnamed route does not track
  /// the screen underneath a second time.
  String? _lastTracked;

  /// Whether to track the `/` route, the name Flutter gives an app's `home`.
  ///
  /// Off by default, so the root route is not tracked, as in earlier versions.
  /// Turn it on to track the home screen like any other named route, for
  /// example to show a survey on it.
  final bool trackRootRoute;

  EncatchNavigatorObserver({this.trackRootRoute = false});

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
    // A dialog or another unnamed route is not a screen: the screen under it
    // stays the last one.
    if (name == null || name.isEmpty) return;
    if (name == _lastTracked) return;
    // Remembered even when not tracked: going back to `/` and then to the
    // screen visited before it is a new visit (home, A, home, A tracks A twice).
    _lastTracked = name;
    if (trackRootRoute || name != '/') {
      final track = internals.autoTrackScreen;
      if (track != null) {
        track(name);
      } else {
        // Before init has been called: handled once it has finished.
        internals.autoScreenBeforeInit = name;
      }
    }
  }
}
