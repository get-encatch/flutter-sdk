/// Shared set-up for SDK tests: a clean SDK pointed at a [FakeApi].
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/internals.dart' as internals;
import 'package:encatch_flutter/src/types.dart' show ShowFormPayload;
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

export 'package:encatch_flutter/src/types.dart' show ShowFormPayload;
export 'package:fake_async/fake_async.dart' show FakeAsync;

export 'fake_api.dart';

/// The app package id the SDK sends as `Referer` in tests.
const testPackageId = 'com.encatch.test';
const fakeBaseUrl = 'https://fake-api.local';

/// Everything [startSdk] does except calling `Encatch.init`: a reset SDK,
/// storage, plugin answers, and the SDK's HTTP client pointed at [api]. Use it
/// directly when the test mounts `EncatchProvider`, which calls `init` itself.
///
/// Storage starts empty unless [stored] is given. Pass `keepStorage: true` to
/// simulate an app restart: the SDK forgets everything in memory but what it
/// saved is still there.
Future<void> prepareSdk(
  FakeApi api, {
  Map<String, Object> stored = const {},
  bool keepStorage = false,
}) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  // Answer the device-info plugin inside the test zone. Without this its reply
  // comes from the real engine, which never arrives under fake time. The empty
  // reply makes the SDK fall back to the host's OS version string.
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/device_info'),
    (call) async => <String, dynamic>{},
  );
  await internals.resetSdkForTest?.call();
  if (!keepStorage) SharedPreferences.setMockInitialValues(stored);
  PackageInfo.setMockInitialValues(
    appName: 'Encatch test',
    packageName: testPackageId,
    version: '9.9.9',
    buildNumber: '1',
    buildSignature: '',
  );
  internals.sdkHttpClient = api.client;
  // The SDK reads the time through this seam, so it follows fake time.
  internals.nowMs = () => clock.now().millisecondsSinceEpoch;
}

/// Resets the SDK, points it at [api] and calls `Encatch.init`.
Future<void> startSdk(
  FakeApi api, {
  String apiKey = defaultApiKey,
  Map<String, Object> stored = const {},
  bool keepStorage = false,
  bool isFullScreen = false,
  bool debugMode = false,
  bool? persistUserAcrossRestarts,
  Future<bool> Function(ShowFormInterceptorPayload payload)? onBeforeShowForm,
  void Function(EncatchRequestInfo info)? onRequest,
  void Function(EncatchResponseInfo info)? onResponse,
  FutureOr<void> Function(SignatureExpiredInfo info)? onSignatureExpired,
}) async {
  await prepareSdk(api, stored: stored, keepStorage: keepStorage);
  await Encatch.init(
    apiKey,
    config: EncatchConfig(
      apiBaseUrl: fakeBaseUrl,
      isFullScreen: isFullScreen,
      debugMode: debugMode,
      onBeforeShowForm: onBeforeShowForm,
      onRequest: onRequest,
      onResponse: onResponse,
      persistUserAcrossRestarts: persistUserAcrossRestarts,
      onSignatureExpired: onSignatureExpired,
    ),
  );
}

/// Stops timers and leaves the SDK uninitialised. Call from `tearDown`.
Future<void> stopSdk() async {
  await internals.resetSdkForTest?.call();
}

/// A test that runs under fake time. [body] gets the clock and a fresh fake
/// API with the SDK already initialised against it.
///
/// Inside [body], nothing asynchronous happens until time is moved: call
/// `async.flushMicrotasks()` after an SDK call to let it run up to its next
/// timer, or `async.elapse(...)` to move the clock.
void testFake(
  String description,
  void Function(FakeAsync async, FakeApi api) body, {
  String apiKey = defaultApiKey,
  Map<String, Object> stored = const {},
  void Function(FakeApi api)? configure,
  bool debugMode = false,
  void Function(EncatchResponseInfo info)? onResponse,
  FutureOr<void> Function(SignatureExpiredInfo info)? onSignatureExpired,
}) {
  test(description, () {
    fakeAsync((async) {
      final api = FakeApi();
      configure?.call(api);
      Object? setupError;
      startSdk(
        api,
        apiKey: apiKey,
        stored: stored,
        debugMode: debugMode,
        onResponse: onResponse,
        onSignatureExpired: onSignatureExpired,
      ).catchError((Object e) => setupError = e);
      async.flushMicrotasks();
      expect(setupError, isNull, reason: 'SDK set-up failed');
      expect(Encatch.isInitialized, isTrue, reason: 'init did not finish');
      try {
        body(async, api);
      } finally {
        stopSdk();
        async.flushMicrotasks();
      }
    });
  });
}

/// Identifies [userName] and waits for the reply. The fake answers at once
/// unless the scenario adds latency.
void identify(FakeAsync async, String userName) {
  Encatch.identifyUser(userName);
  async.flushMicrotasks();
  expect(
    Encatch.userId,
    isNotNull,
    reason: 'identify for $userName did not complete',
  );
}

/// Stands in for the modal or inline presenter: records every form the SDK
/// asks to show and marks it visible, as the real widgets do.
class FakePresenter {
  FakePresenter() {
    _sub = Encatch.onShowForm.listen((payload) {
      shown.add(payload);
      Encatch.setFormVisible(true);
    });
  }

  late final StreamSubscription<ShowFormPayload> _sub;
  final List<ShowFormPayload> shown = [];

  /// The user closed the survey.
  void close() => Encatch.setFormVisible(false);

  void dispose() => _sub.cancel();
}

/// A small app under `EncatchProvider`, with a real navigator watched by an
/// `EncatchNavigatorObserver`. As in a real app, the navigator pushes the first
/// screen while the provider's init is still running.
class TestApp {
  final navigator = GlobalKey<NavigatorState>();
  final observer = EncatchNavigatorObserver();

  /// The app's widget tree. Pumping it again with another
  /// [autoStartVisitorSession] changes the option while the app runs.
  Widget build({
    bool? autoStartVisitorSession,
    bool? persistUserAcrossRestarts,
    bool isFullScreen = false,
    String firstScreen = '/login',
  }) {
    final config = EncatchConfig(
      apiBaseUrl: fakeBaseUrl,
      isFullScreen: isFullScreen,
      persistUserAcrossRestarts: persistUserAcrossRestarts,
    );
    final app = WidgetsApp(
      color: const Color(0xFF000000),
      navigatorKey: navigator,
      navigatorObservers: [observer],
      initialRoute: firstScreen,
      onGenerateRoute: (settings) => PageRouteBuilder<void>(
        settings: settings,
        pageBuilder: (_, _, _) => const SizedBox(),
      ),
    );
    return autoStartVisitorSession == null
        ? EncatchProvider(apiKey: defaultApiKey, config: config, child: app)
        : EncatchProvider(
            apiKey: defaultApiKey,
            config: config,
            autoStartVisitorSession: autoStartVisitorSession,
            child: app,
          );
  }

  /// Launches the app on [firstScreen]. Storage starts as [stored]; pass
  /// `keepStorage: true` for a restart on what an earlier run saved.
  Future<void> launch(
    WidgetTester tester,
    FakeApi api, {
    bool? autoStartVisitorSession,
    bool? persistUserAcrossRestarts,
    bool isFullScreen = false,
    Map<String, Object> stored = const {},
    bool keepStorage = false,
    String firstScreen = '/login',
  }) async {
    await prepareSdk(api, stored: stored, keepStorage: keepStorage);
    await tester.pumpWidget(
      build(
        autoStartVisitorSession: autoStartVisitorSession,
        persistUserAcrossRestarts: persistUserAcrossRestarts,
        isFullScreen: isFullScreen,
        firstScreen: firstScreen,
      ),
    );
    await tester.pump(const Duration(seconds: 2));
  }

  /// Navigates to [screen] and lets two seconds pass.
  Future<void> go(WidgetTester tester, String screen) async {
    navigator.currentState!.pushNamed(screen);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  /// Stops the SDK and takes the app off the screen. Call at the end of the
  /// test, so no timer is left running.
  Future<void> close(WidgetTester tester) async {
    await stopSdk();
    await tester.pumpWidget(const SizedBox());
  }
}

/// Requests sent as a visitor: without identity headers. identify-user is left
/// out, as it always carries the name it identifies.
List<FakeRequest> visitorRequests(FakeApi api, [String? endpoint]) => api
    .requests
    .where(
      (r) =>
          r.endpoint != 'identify-user' &&
          (endpoint == null || r.endpoint == endpoint) &&
          r.userName == null &&
          r.userId == null,
    )
    .toList();

/// Requests sent as [userName], with that user's id.
List<FakeRequest> requestsAs(
  FakeApi api,
  String userName, [
  String? endpoint,
]) => api.requests
    .where(
      (r) =>
          r.endpoint != 'identify-user' &&
          (endpoint == null || r.endpoint == endpoint) &&
          r.userName == userName &&
          r.userId == api.expectedUserId(userName),
    )
    .toList();

/// What an earlier run saved for an identified [userName].
Map<String, Object> savedUser(FakeApi api, String userName) => {
  'encatch_user_name': userName,
  'encatch_user_id_$userName': api.expectedUserId(userName),
};

/// A `$deviceInfo` screen name helper for assertions.
List<String?> screensOf(FakeApi api) =>
    api.of('track-screen').map((r) => r.screen).toList();

/// Event names the fake received on track-event, in order.
List<String?> eventsOf(FakeApi api) =>
    api.of('track-event').map((r) => r.eventName).toList();
