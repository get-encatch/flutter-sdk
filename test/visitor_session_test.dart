// EncatchProvider's autoStartVisitorSession option. With false, a visitor gets
// no ping and no automatic screen tracking until the session starts; the
// default (true) starts the session at every launch, as before.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/internals.dart' as internals;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

List<String?> _screens(List<FakeRequest> requests) =>
    requests.map((r) => r.screen).toList();

/// An app whose navigator sits above the provider, so the first screen is
/// pushed before `Encatch.init` has even been called.
Future<void> _launchWithProviderBelowNavigator(
  WidgetTester tester,
  FakeApi api, {
  required bool autoStartVisitorSession,
}) async {
  await prepareSdk(api);
  // As in a fresh process: nothing of the SDK is set up yet.
  internals.autoTrackScreen = null;
  await tester.pumpWidget(
    WidgetsApp(
      color: const Color(0xFF000000),
      navigatorObservers: [EncatchNavigatorObserver()],
      initialRoute: '/login',
      // The navigator also builds the `/` route under `/login`; the provider
      // is mounted once, on `/login`.
      onGenerateRoute: (settings) => PageRouteBuilder<void>(
        settings: settings,
        pageBuilder: (_, _, _) => settings.name == '/login'
            ? EncatchProvider(
                apiKey: defaultApiKey,
                config: const EncatchConfig(apiBaseUrl: fakeBaseUrl),
                autoStartVisitorSession: autoStartVisitorSession,
                child: const SizedBox(),
              )
            : const SizedBox(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _close(WidgetTester tester) async {
  await stopSdk();
  await tester.pumpWidget(const SizedBox());
}

void main() {
  group('autoStartVisitorSession: false', () {
    testWidgets('a visitor at launch: no ping and no automatic screens', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api, autoStartVisitorSession: false);
      await app.go(tester, '/pricing');
      await tester.pump(const Duration(seconds: 90));

      expect(api.requests, isEmpty);
      await app.close(tester);
    });

    testWidgets('a user restored at launch: the session starts as that user', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(
        tester,
        api,
        autoStartVisitorSession: false,
        stored: savedUser(api, 'alice'),
        firstScreen: '/home',
      );
      await app.go(tester, '/orders');
      await tester.pump(const Duration(seconds: 40));

      expect(api.count('identify-user'), 0);
      expect(_screens(requestsAs(api, 'alice', 'track-screen')), [
        '/home',
        '/orders',
      ]);
      expect(requestsAs(api, 'alice', 'ping').length, greaterThanOrEqualTo(2));
      expect(visitorRequests(api), isEmpty);
      await app.close(tester);
    });

    testWidgets('a name saved without an id counts as a visitor', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(
        tester,
        api,
        autoStartVisitorSession: false,
        stored: {'encatch_user_name': 'alice'},
      );
      await app.go(tester, '/pricing');
      await tester.pump(const Duration(seconds: 90));

      expect(api.requests, isEmpty);
      await app.close(tester);
    });

    testWidgets(
      'a visitor signs in: the session starts and the current screen is sent '
      'once',
      (tester) async {
        final api = FakeApi();
        final app = TestApp();
        await app.launch(tester, api, autoStartVisitorSession: false);
        // The app moves to its home screen before the identify reply is in.
        api.scenario.latency = const Duration(milliseconds: 500);
        Encatch.identifyUser('alice');
        await app.go(tester, '/home');
        api.scenario.latency = Duration.zero;

        expect(api.count('identify-user', status: 200), 1);
        expect(_screens(requestsAs(api, 'alice', 'track-screen')), ['/home']);
        expect(visitorRequests(api), isEmpty);

        // From here on the session runs: later screens and the ping go out.
        await app.go(tester, '/orders');
        await tester.pump(const Duration(seconds: 40));
        expect(_screens(requestsAs(api, 'alice', 'track-screen')), [
          '/home',
          '/orders',
        ]);
        expect(
          requestsAs(api, 'alice', 'ping').length,
          greaterThanOrEqualTo(1),
        );
        expect(visitorRequests(api), isEmpty);
        await app.close(tester);
      },
    );

    testWidgets('an identify while the session runs sends no extra screen', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api, autoStartVisitorSession: false);
      Encatch.identifyUser('alice');
      await app.go(tester, '/home');
      api.clearRequests();

      Encatch.identifyUser('alice', traits: const UserTraits(set: {'a': 1}));
      await tester.pump(const Duration(seconds: 5));
      expect(api.count('identify-user', status: 200), 1);
      expect(api.count('track-screen'), 0);
      await app.close(tester);
    });

    testWidgets('sign-out: the ping and automatic screens stop', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api, autoStartVisitorSession: false);
      Encatch.identifyUser('alice');
      await app.go(tester, '/home');
      await Encatch.resetUser();
      api.clearRequests();

      await app.go(tester, '/login');
      await tester.pump(const Duration(seconds: 90));
      expect(api.requests, isEmpty);
      await app.close(tester);
    });

    testWidgets(
      'sign-out followed straight away by navigation: that screen is not sent',
      (tester) async {
        final api = FakeApi();
        final app = TestApp();
        await app.launch(tester, api, autoStartVisitorSession: false);
        Encatch.identifyUser('alice');
        await app.go(tester, '/home');
        api.clearRequests();

        // Not awaited: the app navigates while the reset is still running.
        Encatch.resetUser();
        await app.go(tester, '/login');
        await tester.pump(const Duration(seconds: 90));
        expect(api.requests, isEmpty);
        await app.close(tester);
      },
    );

    testWidgets("a visitor's own trackScreen and trackEvent are still sent", (
      tester,
    ) async {
      final api = FakeApi()..scenario.allowTrackEventForVisitors = true;
      final app = TestApp();
      await app.launch(tester, api, autoStartVisitorSession: false);

      Encatch.trackScreen('/dev-page');
      Encatch.trackEvent('visitor-event');
      await tester.pump(const Duration(seconds: 90));
      expect(_screens(visitorRequests(api, 'track-screen')), ['/dev-page']);
      expect(eventsOf(api), ['visitor-event']);
      expect(api.count('ping'), 0);
      await app.close(tester);
    });

    testWidgets('startSession() for a visitor starts the session', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api, autoStartVisitorSession: false);

      Encatch.startSession();
      await tester.pump(const Duration(seconds: 2));
      expect(visitorRequests(api, 'ping'), hasLength(1));
      expect(_screens(visitorRequests(api, 'track-screen')), ['/login']);

      await app.go(tester, '/pricing');
      expect(_screens(visitorRequests(api, 'track-screen')), [
        '/login',
        '/pricing',
      ]);
      await app.close(tester);
    });

    testWidgets('a saved stopSession() still wins for a restored user', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(
        tester,
        api,
        autoStartVisitorSession: false,
        stored: {...savedUser(api, 'alice'), 'encatch_session_stopped': true},
        firstScreen: '/home',
      );
      await app.go(tester, '/orders');
      await tester.pump(const Duration(seconds: 90));

      expect(api.requests, isEmpty);
      await app.close(tester);
    });

    testWidgets('clearAll(): automatic screens stop, as after a sign-out', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api, autoStartVisitorSession: false);
      Encatch.identifyUser('alice');
      await app.go(tester, '/home');
      await Encatch.clearAll();
      api.clearRequests();

      await app.go(tester, '/login');
      await tester.pump(const Duration(seconds: 90));
      expect(api.requests, isEmpty);
      await app.close(tester);
    });

    testWidgets('a screen pushed before init was called is not sent either', (
      tester,
    ) async {
      final api = FakeApi();
      await _launchWithProviderBelowNavigator(
        tester,
        api,
        autoStartVisitorSession: false,
      );
      await tester.pump(const Duration(seconds: 90));
      expect(api.requests, isEmpty);

      // It is remembered: starting the session sends it.
      Encatch.startSession();
      await tester.pump(const Duration(seconds: 2));
      expect(_screens(visitorRequests(api, 'track-screen')), ['/login']);
      await _close(tester);
    });

    testWidgets('turned off while the app runs: applies from the next '
        'sign-out', (tester) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api);
      Encatch.identifyUser('alice');
      await app.go(tester, '/home');

      await tester.pumpWidget(app.build(autoStartVisitorSession: false));
      await app.go(tester, '/orders');
      expect(_screens(requestsAs(api, 'alice', 'track-screen')), [
        '/home',
        '/orders',
      ], reason: 'the running session is not affected');

      await Encatch.resetUser();
      api.clearRequests();
      await app.go(tester, '/login');
      await tester.pump(const Duration(seconds: 90));
      expect(api.requests, isEmpty);
      await app.close(tester);
    });
  });

  group('autoStartVisitorSession: the default (true) is unchanged', () {
    testWidgets('a visitor at launch: the ping and the first screen go out', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api);

      expect(visitorRequests(api, 'ping'), hasLength(1));
      expect(_screens(visitorRequests(api, 'track-screen')), ['/login']);
      await app.close(tester);
    });

    testWidgets('after resetUser(), automatic screens go out as a visitor', (
      tester,
    ) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api);
      Encatch.identifyUser('alice');
      await app.go(tester, '/home');
      await Encatch.resetUser();
      api.clearRequests();

      await app.go(tester, '/login');
      expect(_screens(visitorRequests(api, 'track-screen')), ['/login']);
      await app.close(tester);
    });

    testWidgets('a screen pushed before init was called is sent', (
      tester,
    ) async {
      final api = FakeApi();
      await _launchWithProviderBelowNavigator(
        tester,
        api,
        autoStartVisitorSession: true,
      );
      expect(visitorRequests(api, 'ping'), hasLength(1));
      expect(_screens(visitorRequests(api, 'track-screen')), ['/login']);
      await _close(tester);
    });

    testWidgets('a visitor signs in: no extra screen', (tester) async {
      final api = FakeApi();
      final app = TestApp();
      await app.launch(tester, api);
      api.clearRequests();

      Encatch.identifyUser('alice');
      await tester.pump(const Duration(seconds: 5));
      expect(api.count('identify-user', status: 200), 1);
      expect(api.count('track-screen'), 0);
      await app.close(tester);
    });
  });
}
