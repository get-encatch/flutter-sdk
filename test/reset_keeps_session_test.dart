// resetUser() keeps the session running as a visitor: the ping carries on like
// automatic screen tracking does. Before, the reset stopped the ping until the
// next identify or app restart.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  testFake(
    'the ping carries on after a reset, as a visitor, with none at the reset',
    (async, api) {
      identify(async, 'alice');
      // Past the first ping: its reply sets the interval to 30 seconds.
      async.elapse(const Duration(seconds: 15));
      expect(requestsAs(api, 'alice', 'ping'), isNotEmpty);
      final sessionBefore = Encatch.sessionId;

      Encatch.resetUser();
      async.flushMicrotasks();
      api.clearRequests();

      async.elapse(const Duration(seconds: 25));
      expect(api.count('ping'), 0, reason: 'no ping at the reset itself');

      async.elapse(const Duration(seconds: 10));
      expect(visitorRequests(api, 'ping'), hasLength(1));
      expect(api.requests.where((r) => r.userName != null), isEmpty);
      expect(Encatch.sessionId, isNot(sessionBefore));
      expect(
        api.requests.every(
          (r) => r.headers['x-session-id'] == Encatch.sessionId,
        ),
        isTrue,
      );

      async.elapse(const Duration(seconds: 60));
      expect(visitorRequests(api, 'ping'), hasLength(3));
    },
  );

  testFake('after stopSession(): the reset clears the stop and the ping runs', (
    async,
    api,
  ) {
    identify(async, 'alice');
    Encatch.stopSession();
    async.flushMicrotasks();
    Encatch.resetUser();
    async.flushMicrotasks();
    api.clearRequests();

    async.elapse(const Duration(minutes: 2));
    expect(visitorRequests(api, 'ping'), isNotEmpty);
  });

  testFake(
    'after pauseSession(): the reset clears the pause and the ping runs',
    (async, api) {
      identify(async, 'alice');
      Encatch.pauseSession();
      Encatch.resetUser();
      async.flushMicrotasks();
      api.clearRequests();

      async.elapse(const Duration(minutes: 2));
      expect(visitorRequests(api, 'ping'), isNotEmpty);
    },
  );

  testWidgets('launched with a saved stop, then reset: the ping runs', (
    tester,
  ) async {
    final api = FakeApi();
    final app = TestApp();
    await app.launch(
      tester,
      api,
      stored: {...savedUser(api, 'alice'), 'encatch_session_stopped': true},
      firstScreen: '/home',
    );
    await tester.pump(const Duration(seconds: 60));
    expect(api.requests, isEmpty, reason: 'the saved stop holds the launch');

    await Encatch.resetUser();
    await app.go(tester, '/login');
    await tester.pump(const Duration(seconds: 60));
    expect(visitorRequests(api, 'ping'), isNotEmpty);
    expect(visitorRequests(api, 'track-screen').map((r) => r.screen), [
      '/login',
    ]);
    await app.close(tester);
  });

  testFake('a session that never ran is not started by a reset', (async, api) {
    // init only: no provider, no startSession(), no identify.
    Encatch.resetUser();
    async.elapse(const Duration(minutes: 3));
    expect(api.requests, isEmpty);
  });

  testWidgets('full-screen mode: a reset starts no ping', (tester) async {
    final api = FakeApi();
    final app = TestApp();
    await app.launch(tester, api, isFullScreen: true);
    await Encatch.resetUser();
    await tester.pump(const Duration(minutes: 3));
    expect(api.requests, isEmpty);
    await app.close(tester);
  });

  testFake(
    'the server\'s "retries exhausted" reset keeps pinging as a visitor',
    (async, api) {
      identify(async, 'alice');
      api.scenario
        ..userPending = true
        ..userPendingExhaustAfter = 1;
      Encatch.trackEvent('x');
      async.elapse(const Duration(seconds: 2));
      expect(Encatch.userName, isNull, reason: 'the SDK reset the user');
      api.scenario.userPending = false;
      api.clearRequests();

      // That reply asked for the next ping in 15 minutes.
      async.elapse(const Duration(minutes: 16));
      expect(visitorRequests(api, 'ping'), isNotEmpty);
      expect(api.requests.where((r) => r.userName != null), isEmpty);
    },
  );

  testWidgets('autoStartVisitorSession false: the reset stops the ping', (
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
    await tester.pump(const Duration(seconds: 40));
    expect(requestsAs(api, 'alice', 'ping'), isNotEmpty);

    await Encatch.resetUser();
    api.clearRequests();
    await tester.pump(const Duration(minutes: 3));
    expect(api.count('ping'), 0);
    await app.close(tester);
  });
}
