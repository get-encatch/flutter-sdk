// Checks that the test harness itself works: the SDK talks to the fake API,
// fake time drives the SDK's timers, and each test starts from a clean SDK.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/internals.dart' as internals;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  tearDown(stopSdk);

  test('the SDK sends its requests to the fake API', () async {
    final api = FakeApi();
    await startSdk(api);

    await Encatch.identifyUser('alice');
    await pumpEventQueue();

    expect(api.count('identify-user'), 1);
    final request = api.of('identify-user').single;
    expect(request.status, 200);
    expect(request.headers['x-api-key'], defaultApiKey);
    expect(request.headers['referer'], testPackageId);
    expect(request.headers['x-session-id'], isNotEmpty);
    expect(request.headers['x-device-id'], isNotEmpty);
    expect(request.body['userName'], 'alice');
    expect(Encatch.userId, api.expectedUserId('alice'));
  });

  testFake('fake time drives the ping timer', (async, api) {
    Encatch.identifyUser('alice');
    async.flushMicrotasks();
    // A new user is told to ping again in 10 s.
    expect(api.of('identify-user').single.reply?['pingAgainIn'], 10);

    async.elapse(const Duration(seconds: 9));
    expect(api.count('ping'), 0);
    async.elapse(const Duration(seconds: 1));
    expect(api.count('ping'), 1);
    expect(api.of('ping').single.status, 200);

    // The ping reply asks for 30 s.
    async.elapse(const Duration(seconds: 29));
    expect(api.count('ping'), 1);
    async.elapse(const Duration(seconds: 1));
    expect(api.count('ping'), 2);
  });

  test('a reset leaves a clean, uninitialised SDK', () async {
    final first = FakeApi();
    await startSdk(first);
    await Encatch.identifyUser('alice');
    await pumpEventQueue();
    expect(Encatch.userName, 'alice');

    await internals.resetSdkForTest!();
    expect(Encatch.isInitialized, isFalse);
    expect(Encatch.userName, isNull);
    expect(Encatch.userId, isNull);

    final second = FakeApi()..scenario.allowTrackEventForVisitors = true;
    await startSdk(second);
    expect(Encatch.userName, isNull, reason: 'storage starts empty');
    await Encatch.trackEvent('after-reset');
    await pumpEventQueue();
    expect(second.count('track-event'), 1);
    expect(first.count('track-event'), 0);
  });

  test('saved data survives a simulated restart', () async {
    final api = FakeApi();
    await startSdk(api);
    await Encatch.identifyUser('alice');
    await pumpEventQueue();
    final deviceId = Encatch.deviceId;

    await startSdk(api, keepStorage: true);
    expect(Encatch.userName, 'alice');
    expect(Encatch.userId, api.expectedUserId('alice'));
    expect(Encatch.deviceId, deviceId);
  });
}
