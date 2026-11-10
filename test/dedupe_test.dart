// Step 3 (deduplication). Fails on 1.1.2 until the fix lands.
@Tags(['pending-fix'])
library;

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  testFake('twenty identical identifyUser calls send one request', (
    async,
    api,
  ) {
    // Each call finishes before the next. 1.1.2 sends all twenty.
    for (var i = 0; i < 20; i++) {
      Encatch.identifyUser('alice');
      async.flushMicrotasks();
    }
    async.elapse(const Duration(seconds: 5));
    expect(api.count('identify-user'), 1);
    expect(Encatch.userId, api.expectedUserId('alice'));
  });

  testFake('a burst of identical identifyUser calls sends one request', (
    async,
    api,
  ) {
    api.scenario.latency = const Duration(milliseconds: 50);
    for (var i = 0; i < 20; i++) {
      Encatch.identifyUser('alice');
    }
    async.elapse(const Duration(seconds: 5));
    // One more SDK call: 1.1.2 then sends the nineteen it left in the queue.
    Encatch.trackScreen('/home');
    async.elapse(const Duration(seconds: 5));
    expect(api.count('identify-user'), 1);
    expect(screensOf(api), ['/home']);
  });

  testFake('an identify with different traits is sent', (async, api) {
    identify(async, 'alice');
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('identify-user'), 1, reason: 'identical call skipped');

    Encatch.identifyUser(
      'alice',
      traits: const UserTraits(set: {'plan': 'pro'}),
    );
    async.elapse(const Duration(seconds: 2));
    expect(api.count('identify-user'), 2);

    Encatch.identifyUser(
      'alice',
      traits: const UserTraits(set: {'plan': 'pro'}),
      options: const IdentifyOptions(locale: 'fr'),
    );
    async.elapse(const Duration(seconds: 2));
    expect(api.count('identify-user'), 3, reason: 'locale differs');
  });

  testFake('the same identify is sent again after a reset', (async, api) {
    identify(async, 'alice');
    Encatch.resetUser();
    async.flushMicrotasks();
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('identify-user'), 2);
    // And a repeat straight after is still skipped.
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('identify-user'), 2);
  });

  testFake(
    'identical events within one second collapse to one',
    (async, api) {
      for (var i = 0; i < 20; i++) {
        Encatch.trackEvent('tap');
      }
      async.elapse(const Duration(milliseconds: 900));
      expect(eventsOf(api), ['tap']);

      // Outside the window the same event counts again; a different name is
      // never collapsed.
      async.elapse(const Duration(milliseconds: 200));
      Encatch.trackEvent('tap');
      Encatch.trackEvent('other');
      async.elapse(const Duration(seconds: 2));
      expect(eventsOf(api), ['tap', 'tap', 'other']);
    },
    configure: (api) => api.scenario.allowTrackEventForVisitors = true,
  );

  testFake('identical screens collapse, but A, B, A is kept', (async, api) {
    for (var i = 0; i < 20; i++) {
      Encatch.trackScreen('/home');
    }
    async.elapse(const Duration(milliseconds: 500));
    expect(screensOf(api), ['/home']);

    Encatch.trackScreen('/cart');
    Encatch.trackScreen('/home');
    async.elapse(const Duration(seconds: 2));
    expect(screensOf(api), ['/home', '/cart', '/home']);
  });

  test('a screen tracked before init is sent once init finishes', () {
    fakeAsync((async) {
      final api = FakeApi();
      prepareSdk(api);
      async.flushMicrotasks();

      // The navigator pushes the first route before the provider's init ends.
      EncatchNavigatorObserver().didPush(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/home'),
          pageBuilder: (_, _, _) => const SizedBox(),
        ),
        null,
      );
      async.flushMicrotasks();
      expect(api.count('track-screen'), 0);

      // What EncatchProvider does at launch.
      Encatch.init(
        defaultApiKey,
        config: const EncatchConfig(apiBaseUrl: fakeBaseUrl),
      ).then((_) => Encatch.startSession());
      async.elapse(const Duration(seconds: 5));
      expect(screensOf(api), ['/home']);

      stopSdk();
      async.flushMicrotasks();
    });
  });
}
