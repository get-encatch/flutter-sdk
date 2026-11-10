// Step 5 (identity): identity headers both or neither, identify carries its
// own name, and reset and identify run in order. These failed on 1.1.2.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

/// Every request must carry both identity headers or neither (S2).
void expectBothOrNeither(FakeApi api) {
  for (final r in api.requests.where((r) => r.endpoint != 'identify-user')) {
    expect(
      r.userName == null,
      r.userId == null,
      reason: 'half-identified request: $r',
    );
  }
}

void main() {
  testFake(
    'after a failed first identify, requests go out as a visitor',
    (async, api) {
      api.scenario.faults = [
        Fault('identify-user', status: 429, retryAfterSeconds: 1),
      ];
      Encatch.identifyUser('alice');
      async.elapse(const Duration(seconds: 3));

      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      final event = api.of('track-event').single;
      expect(event.userName, isNull);
      expect(event.userId, isNull);
      expect(event.status, 200);
      expect(api.requests.where((r) => r.status == 401), isEmpty);
    },
    configure: (api) => api.scenario.allowTrackEventForVisitors = true,
  );

  testFake('while the first identify is in flight, others go as a visitor', (
    async,
    api,
  ) {
    api.scenario.latency = const Duration(milliseconds: 300);
    Encatch.identifyUser('alice');
    async.elapse(const Duration(milliseconds: 100));
    Encatch.startSession(); // sends a ping straight away
    async.elapse(const Duration(seconds: 2));

    expectBothOrNeither(api);
    expect(api.requests.where((r) => r.status == 401), isEmpty);
    expect(Encatch.userId, api.expectedUserId('alice'));
  });

  testFake('identify never sends a user id, in the header or the body', (
    async,
    api,
  ) {
    identify(async, 'alice');
    Encatch.identifyUser('alice', traits: const UserTraits(set: {'a': 1}));
    Encatch.identifyUser('bob');
    async.elapse(const Duration(seconds: 3));

    final identifies = api.of('identify-user');
    for (final r in identifies) {
      expect(r.userId, isNull, reason: 'X-User-Id on identify: $r');
      expect(r.body.containsKey('userId'), isFalse);
      expect(r.userName, r.body['userName']);
    }
    expect(identifies, hasLength(3));
  });

  testFake('each identify carries its own name after a quick switch', (
    async,
    api,
  ) {
    api.scenario.latency = const Duration(milliseconds: 100);
    Encatch.identifyUser('alice');
    Encatch.identifyUser('bob');
    async.elapse(const Duration(seconds: 3));

    final identifies = api.of('identify-user');
    expect(identifies, isNotEmpty);
    for (final r in identifies) {
      expect(r.userName, r.body['userName']);
    }
    expect(identifies.last.body['userName'], 'bob');
    expect(Encatch.userName, 'bob');
    expect(Encatch.userId, api.expectedUserId('bob'));
  });

  testFake('resetUser then identifyUser, neither awaited, ends as that user', (
    async,
    api,
  ) {
    identify(async, 'alice');
    api.clearRequests();

    Encatch.resetUser();
    Encatch.identifyUser('bob');
    async.elapse(const Duration(seconds: 3));
    expect(Encatch.userName, 'bob');
    expect(Encatch.userId, api.expectedUserId('bob'));
    final identifies = api.of('identify-user');
    expect(identifies, hasLength(1));
    expect(identifies.single.userName, 'bob');

    Encatch.trackEvent('after');
    async.elapse(const Duration(seconds: 2));
    final event = api.of('track-event').single;
    expect(event.userName, 'bob');
    expect(event.userId, api.expectedUserId('bob'));
    expect(api.requests.where((r) => r.status == 401), isEmpty);
  });

  testFake('a late identify reply does not undo a reset', (async, api) {
    api.scenario.latency = const Duration(milliseconds: 300);
    Encatch.identifyUser('alice');
    async.elapse(const Duration(milliseconds: 100));
    Encatch.resetUser();
    async.elapse(const Duration(seconds: 3));
    expect(Encatch.userName, isNull);
    expect(Encatch.userId, isNull);
  });

  testFake(
    'a device left half-identified by 1.1.2 is treated as a visitor',
    (async, api) {
      expect(Encatch.userId, isNull);
      Encatch.trackEvent('after-upgrade');
      async.elapse(const Duration(seconds: 2));
      final event = api.of('track-event').single;
      expect(event.userName, isNull);
      expect(event.userId, isNull);
      expect(event.status, 200);
    },
    // 1.1.2 saved the name before the identify reply arrived.
    stored: {'encatch_user_name': 'alice'},
    configure: (api) => api.scenario.allowTrackEventForVisitors = true,
  );

  testFake('"retries exhausted" in a reply resets the user', (async, api) {
    identify(async, 'alice');
    api.scenario
      ..userPending = true
      ..userPendingExhaustAfter = 1;
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 2));
    expect(
      api.of('track-event').single.reply?['userPendingRetryExhausted'],
      isTrue,
    );
    expect(Encatch.userName, isNull);
    expect(Encatch.userId, isNull);
  });

  testFake('"retries exhausted" in a ping reply resets the user', (async, api) {
    identify(async, 'alice');
    api.scenario
      ..userPending = true
      ..userPendingExhaustAfter = 1;
    // A new user is told to ping again in 10 s.
    async.elapse(const Duration(seconds: 11));
    expect(api.count('ping'), greaterThanOrEqualTo(1));
    expect(Encatch.userName, isNull);
  });

  testFake('the snake_case spelling of the flag is accepted too', (async, api) {
    identify(async, 'alice');
    api.scenario.faults = [
      Fault(
        'track-event',
        status: 200,
        body: {'message': 'ok', 'user_pending_retry_exhausted': true},
      ),
    ];
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 2));
    expect(Encatch.userName, isNull);
  });
  testFake(
    "a request made during a user switch never carries the old user's id",
    (async, api) {
      identify(async, 'alice');
      api.clearRequests();
      api.scenario.latency = const Duration(milliseconds: 300);
      Encatch.identifyUser('bob');
      async.elapse(const Duration(milliseconds: 100));
      Encatch.startSession(); // a ping while bob's identify is in flight
      async.elapse(const Duration(seconds: 2));

      expectBothOrNeither(api);
      final aliceId = api.expectedUserId('alice');
      expect(api.requests.where((r) => r.userId == aliceId), isEmpty);
      expect(api.requests.where((r) => r.status == 401), isEmpty);
      expect(Encatch.userId, api.expectedUserId('bob'));
    },
  );

  testFake('a returning user is sent with both headers straight away', (
    async,
    api,
  ) {
    identify(async, 'alice');
    // Restart: the name and its id were saved.
    startSdk(api, keepStorage: true);
    async.flushMicrotasks();
    api.clearRequests();
    Encatch.trackEvent('after-restart');
    async.elapse(const Duration(seconds: 2));
    final event = api.of('track-event').single;
    expect(event.status, 200);
    expect(event.userName, 'alice');
    expect(event.userId, api.expectedUserId('alice'));
  });
}
