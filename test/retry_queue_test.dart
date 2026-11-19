// Step 1 (retry queue): one flush at a time, per-item backoff, and a request
// timeout. These failed on 1.1.2.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  testFake('a call made while another is in flight is still sent', (
    async,
    api,
  ) {
    api.scenario.latency = const Duration(milliseconds: 100);
    Encatch.identifyUser('alice');
    async.flushMicrotasks();
    Encatch.trackScreen('/home');
    async.flushMicrotasks();

    // No further SDK call is made. 1.1.2 leaves the screen in the queue.
    async.elapse(const Duration(seconds: 5));
    expect(api.count('identify-user'), 1);
    expect(screensOf(api), ['/home']);
  });

  testFake('twenty different events are each sent once', (async, api) {
    api.scenario.latency = const Duration(milliseconds: 20);
    for (var i = 0; i < 20; i++) {
      Encatch.trackEvent('event-$i');
    }
    async.elapse(const Duration(seconds: 8));
    expect(eventsOf(api), [for (var i = 0; i < 20; i++) 'event-$i']);
  }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

  testFake('a request that never answers does not block the queue', (
    async,
    api,
  ) {
    api.scenario.faults = [Fault('track-event', hang: true)];
    Encatch.trackEvent('first');
    async.flushMicrotasks();
    Encatch.trackEvent('second');
    async.flushMicrotasks();

    // The first request times out after 30 s; the second then goes out.
    async.elapse(const Duration(seconds: 31));
    expect(eventsOf(api).where((e) => e == 'second'), hasLength(1));
  }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

  testFake(
    'a failed call waits for its backoff even when another call arrives',
    (async, api) {
      api.scenario.faults = [Fault('track-event', status: 503)];
      Encatch.trackEvent('a');
      async.flushMicrotasks();
      expect(eventsOf(api), ['a']);

      async.elapse(const Duration(milliseconds: 500));
      Encatch.trackEvent('b');
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 500));
      // 1 s after the failure: 'b' has gone out, 'a' is still backing off (2 s).
      expect(eventsOf(api).where((e) => e == 'a'), hasLength(1));
      expect(eventsOf(api).where((e) => e == 'b'), hasLength(1));

      async.elapse(const Duration(seconds: 2));
      final attempts = api.of('track-event').where((r) => r.eventName == 'a');
      expect(attempts, hasLength(2));
      expect(attempts.last.status, 200);
    },
    configure: (api) => api.scenario.allowTrackEventForVisitors = true,
  );
}
