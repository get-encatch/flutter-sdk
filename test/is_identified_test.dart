// Encatch.isIdentified: true when the SDK has a confirmed identity, which
// means the user was restored from the device at init or their identify
// succeeded.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';
import 'secure_identify_test.dart' show secureIdentify;

void main() {
  test('false before init has finished', () async {
    final api = FakeApi();
    addTearDown(stopSdk);
    await prepareSdk(api, stored: savedUser(api, 'alice'));
    expect(Encatch.isIdentified, isFalse);

    final init = Encatch.init(
      defaultApiKey,
      config: const EncatchConfig(apiBaseUrl: fakeBaseUrl),
    );
    expect(Encatch.isIdentified, isFalse, reason: 'init is still running');
    await init;
    expect(Encatch.isIdentified, isTrue);
  });

  testFake('false for a visitor', (async, api) {
    expect(Encatch.isIdentified, isFalse);
    Encatch.startSession();
    async.elapse(const Duration(seconds: 5));
    expect(Encatch.isIdentified, isFalse);
  });

  testFake('true after an identify succeeds', (async, api) {
    identify(async, 'alice');
    expect(Encatch.isIdentified, isTrue);
  });

  test('true for a returning user as soon as init finishes', () async {
    final api = FakeApi();
    addTearDown(stopSdk);
    await startSdk(api, stored: savedUser(api, 'alice'));
    expect(Encatch.isIdentified, isTrue);
    expect(api.requests, isEmpty, reason: 'no identify was needed');
  });

  test('false for a name saved without an id', () async {
    final api = FakeApi();
    addTearDown(stopSdk);
    await startSdk(api, stored: {'encatch_user_name': 'alice'});
    expect(Encatch.isIdentified, isFalse);
  });

  testFake("false while a new user's first identify is pending", (async, api) {
    api.scenario.latency = const Duration(seconds: 2);
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 1));
    expect(Encatch.isIdentified, isFalse);

    async.elapse(const Duration(seconds: 2));
    expect(Encatch.isIdentified, isTrue);
  });

  testFake("false after a new user's first identify failed", (async, api) {
    api.scenario.faults = [Fault('identify-user', status: 400)];
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 5));
    expect(api.count('identify-user', status: 400), 1);
    expect(Encatch.isIdentified, isFalse);
  });

  group('switching from one user to another', () {
    testFake("stays true while the new user's identify is pending", (
      async,
      api,
    ) {
      identify(async, 'alice');
      api.scenario.latency = const Duration(seconds: 2);
      Encatch.identifyUser('bob');
      async.elapse(const Duration(seconds: 1));
      expect(Encatch.isIdentified, isTrue, reason: 'still the previous user');

      async.elapse(const Duration(seconds: 2));
      expect(Encatch.isIdentified, isTrue);
      expect(Encatch.userName, 'bob');
      expect(Encatch.userId, api.expectedUserId('bob'));
    });

    testFake("stays true when the new user's identify fails", (async, api) {
      identify(async, 'alice');
      api.scenario.faults = [Fault('identify-user', status: 400)];
      Encatch.identifyUser('bob');
      async.elapse(const Duration(seconds: 5));
      expect(api.count('identify-user', status: 400), 1);
      expect(Encatch.isIdentified, isTrue, reason: 'still the previous user');
    });
  });

  group('back to false', () {
    testFake('after resetUser()', (async, api) {
      identify(async, 'alice');
      Encatch.resetUser();
      async.flushMicrotasks();
      expect(Encatch.isIdentified, isFalse);
    });

    testFake('after clearAll()', (async, api) {
      identify(async, 'alice');
      Encatch.clearAll();
      async.flushMicrotasks();
      expect(Encatch.isIdentified, isFalse);
    });

    testFake('after the server\'s "retries exhausted" reset', (async, api) {
      identify(async, 'alice');
      api.scenario
        ..userPending = true
        ..userPendingExhaustAfter = 1;
      Encatch.trackEvent('x');
      async.elapse(const Duration(seconds: 2));
      expect(Encatch.userName, isNull);
      expect(Encatch.isIdentified, isFalse);
    });
  });

  group('unchanged', () {
    testFake('by stopSession()', (async, api) {
      identify(async, 'alice');
      Encatch.stopSession();
      async.flushMicrotasks();
      expect(Encatch.isIdentified, isTrue);
    });

    testFake(
      'when the secure signature expires',
      (async, api) {
        secureIdentify(async, api, 'alice', secureSessionApiKey);
        expect(Encatch.isIdentified, isTrue);

        // Past the key's 15 minute session time a ping gets 401, and the SDK
        // stops tracking until the app identifies again.
        async.elapse(const Duration(minutes: 17));
        expect(api.requests.where((r) => r.status == 401), hasLength(1));
        expect(Encatch.isIdentified, isTrue);
      },
      apiKey: secureSessionApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );
  });
}
