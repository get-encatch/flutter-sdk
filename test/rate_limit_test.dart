// Step 2 (429 pause): a 429 pauses its bucket for Retry-After. These failed on
// 1.1.2.
import 'dart:io' show HttpDate;

import 'package:clock/clock.dart';
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

const _submit = SubmitFormRequest(
  triggerType: TriggerType.manual,
  formDetails: FormDetails(
    formConfigurationId: defaultFormId,
    isPartialSubmit: false,
  ),
);

void main() {
  testFake('a 429 pauses tracking calls for Retry-After, then resumes', (
    async,
    api,
  ) {
    identify(async, 'alice');
    api.clearRequests();
    api.scenario.faults = [
      Fault('track-event', status: 429, retryAfterSeconds: 60),
    ];

    Encatch.trackEvent('a');
    async.flushMicrotasks();
    expect(api.of('track-event').single.status, 429);

    async.elapse(const Duration(seconds: 2));
    Encatch.trackEvent('b');
    Encatch.trackScreen('/cart');
    async.elapse(const Duration(seconds: 55));
    // Nothing in the tracking bucket goes out during the pause: no event, no
    // screen, no ping.
    expect(eventsOf(api), ['a']);
    expect(api.count('track-screen'), 0);
    expect(api.count('ping'), 0);

    async.elapse(const Duration(seconds: 5));
    Encatch.trackEvent('c');
    async.elapse(const Duration(seconds: 2));
    // The 429'd call is never retried, the skipped call is not sent later, and
    // new calls go out again.
    expect(eventsOf(api), ['a', 'c']);
    expect(api.of('track-event').last.status, 200);
  });

  testFake('calls already queued are held, then sent once the pause ends', (
    async,
    api,
  ) {
    identify(async, 'alice');
    api.clearRequests();
    api.scenario.latency = const Duration(milliseconds: 100);
    api.scenario.faults = [
      Fault('track-event', status: 429, retryAfterSeconds: 20),
    ];
    // 'b' and 'c' are queued while 'a' is still in flight.
    Encatch.trackEvent('a');
    Encatch.trackEvent('b');
    Encatch.trackEvent('c');
    async.elapse(const Duration(seconds: 15));
    expect(eventsOf(api), ['a']);

    async.elapse(const Duration(seconds: 7));
    expect(eventsOf(api), ['a', 'b', 'c']);
    expect(api.count('track-event', status: 200), 2);
  });

  testFake('Retry-After can be an HTTP date', (async, api) {
    identify(async, 'alice');
    api.clearRequests();
    final until = clock.now().add(const Duration(seconds: 30));
    api.scenario.faults = [
      Fault('track-event', status: 429, retryAfter: HttpDate.format(until)),
    ];
    Encatch.trackEvent('a');
    async.flushMicrotasks();

    async.elapse(const Duration(seconds: 25));
    Encatch.trackEvent('b');
    async.elapse(const Duration(seconds: 2));
    expect(eventsOf(api), ['a']);

    async.elapse(const Duration(seconds: 5));
    Encatch.trackEvent('c');
    async.elapse(const Duration(seconds: 2));
    expect(eventsOf(api), ['a', 'c']);
  });

  testFake('without Retry-After the pause is 60 s', (async, api) {
    identify(async, 'alice');
    api.clearRequests();
    api.scenario.faults = [Fault('track-event', status: 429)];
    Encatch.trackEvent('a');
    async.flushMicrotasks();

    async.elapse(const Duration(seconds: 58));
    Encatch.trackEvent('b');
    async.elapse(const Duration(seconds: 1));
    expect(eventsOf(api), ['a']);

    async.elapse(const Duration(seconds: 3));
    Encatch.trackEvent('c');
    async.elapse(const Duration(seconds: 2));
    expect(eventsOf(api), ['a', 'c']);
  });

  testFake('the pause is capped at five minutes', (async, api) {
    identify(async, 'alice');
    api.clearRequests();
    api.scenario.faults = [
      Fault('track-event', status: 429, retryAfterSeconds: 3600),
    ];
    Encatch.trackEvent('a');
    async.flushMicrotasks();

    async.elapse(const Duration(minutes: 4, seconds: 55));
    Encatch.trackEvent('b');
    async.elapse(const Duration(seconds: 2));
    expect(eventsOf(api), ['a']);

    async.elapse(const Duration(seconds: 5));
    Encatch.trackEvent('c');
    async.elapse(const Duration(seconds: 2));
    expect(eventsOf(api), ['a', 'c']);
  });

  testFake('a 429 on submit-form is retried after the pause, not lost', (
    async,
    api,
  ) {
    identify(async, 'alice');
    api.scenario.faults = [
      Fault('submit-form', status: 429, retryAfterSeconds: 10),
    ];
    var done = false;
    Object? error;
    Encatch.submitForm(_submit).then(
      (_) {
        done = true;
      },
      onError: (Object e) {
        error = e;
      },
    );
    async.flushMicrotasks();
    expect(api.of('submit-form').single.status, 429);

    async.elapse(const Duration(seconds: 11));
    expect(api.count('submit-form'), 2);
    expect(api.of('submit-form').last.status, 200);
    expect(error, isNull);
    expect(done, isTrue);
  });

  testFake(
    'an identify made during a pause is held, and only the latest is sent',
    (async, api) {
      api.scenario.faults = [
        Fault('track-event', status: 429, retryAfterSeconds: 30),
      ];
      Encatch.trackEvent('x');
      async.flushMicrotasks();

      Encatch.identifyUser('alice');
      async.flushMicrotasks();
      Encatch.identifyUser('bob');
      async.elapse(const Duration(seconds: 28));
      expect(api.count('identify-user'), 0);

      async.elapse(const Duration(seconds: 4));
      expect(api.of('identify-user').map((r) => r.body['userName']), ['bob']);
      expect(Encatch.userName, 'bob');
      expect(Encatch.userId, api.expectedUserId('bob'));
    },
    configure: (api) => api.scenario.allowTrackEventForVisitors = true,
  );

  testFake('a 429 on show-form pauses shows but not tracking', (async, api) {
    identify(async, 'alice');
    api.clearRequests();
    api.scenario.faults = [
      Fault('show-form', status: 429, retryAfterSeconds: 30),
    ];
    Encatch.showForm(defaultFormId);
    async.flushMicrotasks();
    expect(api.of('show-form').single.status, 429);

    Encatch.showForm(secondFormId);
    Encatch.trackEvent('still-tracked');
    async.elapse(const Duration(seconds: 5));
    expect(api.count('show-form'), 1, reason: 'shows are paused');
    expect(eventsOf(api), ['still-tracked']);

    async.elapse(const Duration(seconds: 27));
    Encatch.showForm(secondFormId);
    async.flushMicrotasks();
    expect(api.count('show-form'), 2);
    expect(api.of('show-form').last.status, 200);
  });
}
