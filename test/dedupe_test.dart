// Step 3 (deduplication): identical identify, event and screen calls are sent
// once. These failed on 1.1.2.
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

  testFake('the same identify is sent again after one that failed', (
    async,
    api,
  ) {
    // Rejected outright (4xx): given up on at once.
    api.scenario.faults = [Fault('identify-user', status: 400)];
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 2));
    expect(api.of('identify-user').single.status, 400);
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('identify-user'), 2);
    expect(api.of('identify-user').last.status, 200);

    // Failing three times (5xx): given up on after the last attempt.
    api.clearRequests();
    api.scenario.faults = [Fault('identify-user', count: 3, status: 503)];
    Encatch.identifyUser('bob');
    async.elapse(const Duration(seconds: 3));
    Encatch.identifyUser('bob'); // still retrying: skipped
    async.elapse(const Duration(seconds: 10));
    expect(api.count('identify-user'), 3);
    Encatch.identifyUser('bob');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('identify-user'), 4);
    expect(Encatch.userId, api.expectedUserId('bob'));
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

  testFake('identical events within one second collapse to one', (async, api) {
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
  }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

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

  testFake('the observer tracks a route only when its name changes', (
    async,
    api,
  ) {
    Route<void> route(String? name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, _, _) => const SizedBox(),
    );
    final observer = EncatchNavigatorObserver();
    final home = route('/home');
    final dialog = route(null);
    final cart = route('/cart');

    observer.didPush(home, null);
    async.elapse(const Duration(seconds: 3));
    // Opening and closing a dialog (an unnamed route) over the screen.
    observer.didPush(dialog, home);
    async.elapse(const Duration(seconds: 3));
    observer.didPop(dialog, home);
    async.elapse(const Duration(seconds: 3));
    expect(screensOf(api), ['/home'], reason: 'not tracked a second time');

    observer.didPush(cart, home);
    async.elapse(const Duration(seconds: 3));
    observer.didPop(cart, home);
    async.elapse(const Duration(seconds: 3));
    expect(screensOf(api), ['/home', '/cart', '/home']);
  });

  testFake('a screen visited again after the root route is tracked again', (
    async,
    api,
  ) {
    Route<void> route(String? name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, _, _) => const SizedBox(),
    );
    // The usual app: its first screen is MaterialApp's `home`, the route `/`,
    // which is not tracked.
    final observer = EncatchNavigatorObserver();
    final root = route('/');
    final ops = route('/rp-ops');
    final dialog = route(null);

    observer.didPush(root, null);
    async.elapse(const Duration(seconds: 3));
    observer.didPush(ops, root);
    async.elapse(const Duration(seconds: 3));
    // A dialog over it does not count.
    observer.didPush(dialog, ops);
    async.elapse(const Duration(seconds: 3));
    observer.didPop(dialog, ops);
    async.elapse(const Duration(seconds: 3));
    observer.didPop(ops, root);
    async.elapse(const Duration(seconds: 3));
    observer.didPush(route('/rp-ops'), root);
    async.elapse(const Duration(seconds: 3));
    expect(screensOf(api), [
      '/rp-ops',
      '/rp-ops',
    ], reason: 'the second visit, after home, is a visit');
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
