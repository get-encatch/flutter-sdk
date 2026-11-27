// Step 12: the optional debug hooks, EncatchConfig.onRequest and onResponse.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

/// Runs [body] under fake time with the hooks recording into the lists.
void hookTest(
  String description,
  void Function(
    FakeAsync async,
    FakeApi api,
    List<EncatchRequestInfo> requests,
    List<EncatchResponseInfo> responses,
  )
  body, {
  String apiKey = defaultApiKey,
}) {
  test(description, () {
    fakeAsync((async) {
      final api = FakeApi()..scenario.allowTrackEventForVisitors = true;
      final requests = <EncatchRequestInfo>[];
      final responses = <EncatchResponseInfo>[];
      startSdk(
        api,
        apiKey: apiKey,
        onRequest: requests.add,
        onResponse: responses.add,
      );
      async.flushMicrotasks();
      try {
        body(async, api, requests, responses);
      } finally {
        stopSdk();
        async.flushMicrotasks();
      }
    });
  });
}

List<String> skipped(List<EncatchResponseInfo> responses) => [
  for (final r in responses)
    if (r.outcome == 'skipped') '${r.endpoint}:${r.reason}',
];

void main() {
  hookTest('each request is reported once, before and after', (
    async,
    api,
    requests,
    responses,
  ) {
    Encatch.identifyUser('alice');
    Encatch.trackEvent('tap');
    Encatch.trackScreen('/home');
    async.elapse(const Duration(seconds: 2));

    expect(requests.map((r) => r.endpoint), [
      'identify-user',
      'track-event',
      'track-screen',
    ]);
    expect(requests.every((r) => r.attempt == 1), isTrue);
    expect(responses, hasLength(api.requests.length));
    for (final r in responses) {
      expect(r.outcome, 'ok');
      expect(r.status, 200);
      expect(r.rateLimited, isFalse);
      expect(r.reason, isNull);
      expect(r.durationMs, greaterThanOrEqualTo(0));
    }
  });

  hookTest('a failed reply, a 429 and a lost connection', (
    async,
    api,
    requests,
    responses,
  ) {
    api.scenario.faults = [
      Fault('track-event', status: 400),
      Fault('track-screen', drop: true),
      Fault('show-form', status: 429, retryAfterSeconds: 5),
    ];
    Encatch.trackEvent('bad');
    async.elapse(const Duration(seconds: 1));
    final bad = responses.single;
    expect(
      (bad.endpoint, bad.outcome, bad.status),
      ('track-event', 'error', 400),
    );

    responses.clear();
    Encatch.trackScreen('/dropped');
    async.elapse(const Duration(seconds: 1));
    final dropped = responses.single;
    expect(dropped.outcome, 'network-error');
    expect(dropped.status, isNull);

    responses.clear();
    Encatch.showForm(defaultFormId);
    async.flushMicrotasks();
    final limited = responses.single;
    expect((limited.outcome, limited.status), ('error', 429));
    expect(limited.rateLimited, isTrue);
  });

  hookTest('retries carry the attempt number', (
    async,
    api,
    requests,
    responses,
  ) {
    api.scenario.faults = [Fault('track-event', count: 2, status: 503)];
    Encatch.trackEvent('flaky');
    async.elapse(const Duration(seconds: 10));
    expect(requests.map((r) => r.attempt), [1, 2, 3]);
    expect(responses.map((r) => (r.attempt, r.status)), [
      (1, 503),
      (2, 503),
      (3, 200),
    ]);
  });

  hookTest('calls the SDK does not send are reported as skipped', (
    async,
    api,
    requests,
    responses,
  ) {
    // A survey event from a visitor.
    Encatch.trackFormEvent('form:show', defaultFormId);
    async.flushMicrotasks();
    expect(skipped(responses), ['track-event:visitor']);
    expect(requests, isEmpty);

    // Identical calls.
    responses.clear();
    Encatch.identifyUser('alice');
    Encatch.identifyUser('alice');
    Encatch.trackEvent('tap');
    Encatch.trackEvent('tap');
    Encatch.trackScreen('/home');
    Encatch.trackScreen('/home');
    async.elapse(const Duration(seconds: 2));
    // The identify duplicate is found once earlier identity calls have run,
    // so it may be reported after the others.
    expect(
      skipped(responses),
      unorderedEquals([
        'identify-user:duplicate',
        'track-event:collapsed',
        'track-screen:collapsed',
      ]),
    );

    // A survey is open: the same form again, and an automatic one.
    final presenter = FakePresenter();
    Encatch.showForm(defaultFormId);
    async.flushMicrotasks();
    responses.clear();
    Encatch.showForm(defaultFormId);
    api.scenario.eventTriggers = {
      'purchase': const SurveyTrigger(secondFormId),
    };
    Encatch.trackEvent('purchase');
    async.elapse(const Duration(seconds: 2));
    expect(skipped(responses), [
      'show-form:survey-open',
      'show-form:survey-open',
    ]);
    presenter.close();
    presenter.dispose();

    // During the pause after a 429.
    api.scenario.faults = [
      Fault('track-event', status: 429, retryAfterSeconds: 30),
    ];
    Encatch.trackEvent('limited');
    async.elapse(const Duration(seconds: 2));
    responses.clear();
    Encatch.trackEvent('during-pause');
    Encatch.trackScreen('/during-pause');
    async.flushMicrotasks();
    expect(skipped(responses), [
      'track-event:rate-limited',
      'track-screen:rate-limited',
    ]);
    expect(responses.every((r) => r.rateLimited), isTrue);
  });

  hookTest('after a signature expires, skipped calls say so', (
    async,
    api,
    requests,
    responses,
  ) {
    api.scenario.enforceSignatureOnAllRequests = true;
    final signed = api.sign('alice', secureSessionApiKey);
    Encatch.identifyUser(
      'alice',
      options: IdentifyOptions(
        secure: SecureOptions(
          signature: signed.signature,
          generatedDateTimeinUTC: signed.time,
        ),
      ),
    );
    async.elapse(const Duration(minutes: 17));
    responses.clear();
    Encatch.trackEvent('late');
    async.flushMicrotasks();
    expect(skipped(responses), ['track-event:signature-expired']);
  }, apiKey: secureSessionApiKey);

  test('a hook that throws, or fails later, does not affect the SDK', () {
    fakeAsync((async) {
      final api = FakeApi();
      startSdk(
        api,
        onRequest: (_) => throw StateError('hook failed'),
        onResponse: (_) async => throw StateError('async hook failed'),
      );
      async.flushMicrotasks();
      Encatch.identifyUser('alice');
      Encatch.trackScreen('/home');
      async.elapse(const Duration(seconds: 2));
      expect(api.count('identify-user', status: 200), 1);
      expect(api.count('track-screen', status: 200), 1);
      expect(Encatch.userId, api.expectedUserId('alice'));
      stopSdk();
      async.flushMicrotasks();
    });
  });

  test('the hook data has no place for a key, a header or a body', () {
    // The two info types carry these fields and nothing else.
    const request = EncatchRequestInfo(endpoint: 'ping', attempt: 1);
    const response = EncatchResponseInfo(
      endpoint: 'ping',
      attempt: 1,
      outcome: 'ok',
      status: 200,
      durationMs: 12,
    );
    expect((request.endpoint, request.attempt), ('ping', 1));
    expect(
      (
        response.endpoint,
        response.attempt,
        response.outcome,
        response.status,
        response.durationMs,
        response.rateLimited,
        response.reason,
      ),
      ('ping', 1, 'ok', 200, 12, false, null),
    );
  });

  group('EncatchNavigatorObserver(trackRootRoute)', () {
    Route<void> route(String? name) => PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, _, _) => const SizedBox(),
    );

    testFake('off by default: the "/" route is not tracked', (async, api) {
      final observer = EncatchNavigatorObserver();
      observer.didPush(route('/'), null);
      observer.didPush(route('/cart'), null);
      observer.didPop(route('/cart'), route('/'));
      async.elapse(const Duration(seconds: 3));
      expect(screensOf(api), ['/cart']);
    });

    testFake('on: "/" is tracked like any other route', (async, api) {
      final observer = EncatchNavigatorObserver(trackRootRoute: true);
      observer.didPush(route('/'), null);
      async.elapse(const Duration(seconds: 3));
      observer.didPush(route('/cart'), null);
      async.elapse(const Duration(seconds: 3));
      observer.didPop(route('/cart'), route('/'));
      async.elapse(const Duration(seconds: 3));
      expect(screensOf(api), ['/', '/cart', '/']);
    });

    test('on: a "/" pushed before init is sent once init finishes', () {
      fakeAsync((async) {
        final api = FakeApi();
        prepareSdk(api);
        async.flushMicrotasks();
        EncatchNavigatorObserver(
          trackRootRoute: true,
        ).didPush(route('/'), null);
        Encatch.init(
          defaultApiKey,
          config: const EncatchConfig(apiBaseUrl: fakeBaseUrl),
        ).then((_) => Encatch.startSession());
        async.elapse(const Duration(seconds: 5));
        expect(screensOf(api), ['/']);
        stopSdk();
        async.flushMicrotasks();
      });
    });
  });
}
