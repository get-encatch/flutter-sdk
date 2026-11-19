// Behaviour of 1.1.2 that the 1.2.0 fixes must not change. These pass today
// and must keep passing after every step.
import 'dart:io';

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  test('calls made before init do nothing', () async {
    final api = FakeApi();
    await prepareSdk(api);
    await Encatch.identifyUser('alice');
    await Encatch.trackEvent('early');
    await Encatch.showForm(defaultFormId);
    await pumpEventQueue();
    expect(api.requests, isEmpty);
    expect(Encatch.isInitialized, isFalse);
  });

  test('full-screen mode skips tracking', () async {
    final api = FakeApi();
    addTearDown(stopSdk);
    await startSdk(api, isFullScreen: true);
    await Encatch.trackEvent('ignored');
    await Encatch.trackScreen('/ignored');
    await Encatch.startSession();
    await pumpEventQueue();
    expect(api.requests, isEmpty);
  });

  testFake('a 4xx drops that call and the next one still goes out', (
    async,
    api,
  ) {
    api.scenario.faults = [Fault('track-event', status: 400)];
    Encatch.trackEvent('bad');
    async.flushMicrotasks();
    Encatch.trackEvent('good');
    async.elapse(const Duration(seconds: 10));
    expect(eventsOf(api), ['bad', 'good']);
    expect(api.of('track-event').last.status, 200);
  }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

  testFake(
    'a 5xx is tried three times in all, 2 s then 4 s apart, then dropped',
    (async, api) {
      api.scenario.faults = [Fault('track-event', count: 10, status: 503)];
      Encatch.trackEvent('flaky');
      async.flushMicrotasks();
      expect(api.count('track-event'), 1);
      async.elapse(const Duration(milliseconds: 1900));
      expect(api.count('track-event'), 1);
      async.elapse(const Duration(milliseconds: 200));
      expect(api.count('track-event'), 2);
      async.elapse(const Duration(milliseconds: 3700));
      expect(api.count('track-event'), 2);
      async.elapse(const Duration(milliseconds: 400));
      expect(api.count('track-event'), 3);
      async.elapse(const Duration(minutes: 1));
      expect(api.count('track-event'), 3, reason: 'dropped after 3 attempts');
    },
    configure: (api) => api.scenario.allowTrackEventForVisitors = true,
  );

  testFake("a 429'd tracking call is never retried", (async, api) {
    api.scenario.faults = [
      Fault('track-event', status: 429, retryAfterSeconds: 5),
    ];
    Encatch.trackEvent('limited');
    async.elapse(const Duration(minutes: 10));
    expect(eventsOf(api), ['limited']);
  }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

  testFake('a manual showForm for a different form replaces the open one', (
    async,
    api,
  ) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    Encatch.showForm(defaultFormId);
    async.flushMicrotasks();
    Encatch.showForm(secondFormId);
    async.flushMicrotasks();
    expect(presenter.shown.map((p) => p.formId), [defaultFormId, secondFormId]);
    expect(presenter.shown.last.triggerType, TriggerType.manual);
    presenter.dispose();
  });

  testFake('no ping goes out while a form is visible', (async, api) {
    identify(async, 'alice');
    Encatch.setFormVisible(true);
    async.elapse(const Duration(minutes: 2));
    expect(api.count('ping'), 0);

    Encatch.setFormVisible(false);
    async.elapse(const Duration(minutes: 1));
    expect(api.count('ping'), greaterThanOrEqualTo(1));
  });

  testFake('a survey in a track-screen reply is shown after its delay', (
    async,
    api,
  ) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    api.scenario.screenTriggers = {
      '/checkout': const SurveyTrigger(defaultFormId, onPageDelay: 5),
    };
    Encatch.trackScreen('/checkout');
    async.elapse(const Duration(seconds: 4));
    expect(api.count('show-form'), 0);
    async.elapse(const Duration(seconds: 2));
    expect(api.count('show-form'), 1);
    expect(api.of('show-form').single.body['triggerType'], 'automatic');
    expect(presenter.shown.single.formId, defaultFormId);
    presenter.dispose();
  });

  testFake("an identified user's survey events are sent with both headers", (
    async,
    api,
  ) {
    identify(async, 'alice');
    api.clearRequests();
    for (final name in ['form:show', 'form:started', 'form:complete']) {
      Encatch.trackFormEvent(name, defaultFormId);
    }
    async.flushMicrotasks();
    expect(eventsOf(api), ['form:show', 'form:started', 'form:complete']);
    for (final r in api.of('track-event')) {
      expect(r.status, 200);
      expect(r.userName, 'alice');
      expect(r.userId, api.expectedUserId('alice'));
      expect(r.body['feedbackConfigurationId'], defaultFormId);
    }
  });

  testFake("a visitor's own trackEvent still goes out", (async, api) {
    Encatch.trackEvent('visitor-tap');
    async.flushMicrotasks();
    final event = api.of('track-event').single;
    expect(event.status, 200);
    expect(event.userName, isNull);
    expect(event.userId, isNull);
  }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

  testFake('a successful identify resumes a stopped session', (async, api) {
    identify(async, 'alice');
    Encatch.stopSession();
    async.flushMicrotasks();
    api.clearRequests();
    async.elapse(const Duration(minutes: 2));
    expect(api.count('ping'), 0);

    Encatch.identifyUser('bob');
    async.elapse(const Duration(minutes: 2));
    expect(Encatch.userName, 'bob');
    expect(api.count('ping'), greaterThanOrEqualTo(1));
  });

  testFake(r'every request reports the package version as $sdkVersion', (
    async,
    api,
  ) {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    identify(async, 'alice');
    Encatch.trackScreen('/v');
    async.flushMicrotasks();
    for (final r in api.requests) {
      expect((r.body[r'$deviceInfo'] as Map)[r'$sdkVersion'], version);
    }
  });
}
