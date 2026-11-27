// Encatch.setUserProperties(userName, traits), as in React Native
// 1.5.0-beta.2: updates the identified user's properties through identify-user.
// Never deduped; sent only for the current, confirmed user.
import 'dart:async';

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/logger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';
import 'secure_identify_test.dart' show secureIdentify;

final _skips = <String>[];
void _onResponse(EncatchResponseInfo info) {
  if (info.outcome == 'skipped') _skips.add('${info.endpoint} ${info.reason}');
}

/// identify-user requests that carried properties (setUserProperties sends a
/// user id in the body; identify never does).
List<FakeRequest> _updates(FakeApi api) =>
    api.of('identify-user').where((r) => r.body['userId'] != null).toList();

const _pro = UserTraits(set: {'plan': 'pro'});

void main() {
  setUp(_skips.clear);
  tearDown(() => EncatchLogger.sink = null);

  group('sent', () {
    testFake(
      'for the confirmed user: name, user id, traits with ISO dates, and '
      'the stored signature, which stays',
      (async, api) {
        secureIdentify(async, api, 'alice', secureSessionApiKey);
        async.elapse(const Duration(seconds: 1));
        final at = DateTime.utc(2026, 11, 27);
        Encatch.setUserProperties(
          'alice',
          UserTraits(set: {'since': at}, increment: const {'logins': 1}),
        );
        async.elapse(const Duration(seconds: 2));

        final update = _updates(api).single;
        expect(update.status, 200);
        expect(update.userName, 'alice');
        expect(update.body['userName'], 'alice');
        expect(update.body['userId'], api.expectedUserId('alice'));
        expect(update.body['userAttributes'], {
          r'$set': {'since': at.toIso8601String()},
          r'$increment': {'logins': 1},
        });
        final identify = api.of('identify-user').first;
        expect(
          update.headers['x-user-signature'],
          identify.headers['x-user-signature'],
        );
        expect(
          update.headers['x-user-session-time'],
          identify.headers['x-user-session-time'],
        );

        api.clearRequests();
        Encatch.trackEvent('after');
        async.elapse(const Duration(seconds: 2));
        expect(
          api.of('track-event').single.headers['x-user-signature'],
          identify.headers['x-user-signature'],
        );
      },
      apiKey: secureSessionApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );

    testFake('never deduped: the same traits twice send two', (async, api) {
      identify(async, 'alice');
      Encatch.setUserProperties('alice', _pro);
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 3));
      expect(_updates(api).map((r) => r.status), [200, 200]);
    });

    testFake('a new user: await identify, then the update goes out after the '
        'identify succeeds', (async, api) {
      api.scenario.latency = const Duration(milliseconds: 300);
      Encatch.identifyUser(
        'bob',
      ).then((_) => Encatch.setUserProperties('bob', _pro));
      async.elapse(const Duration(seconds: 3));
      final all = api.of('identify-user');
      expect(all.map((r) => r.body['userId'] != null), [false, true]);
      expect(_updates(api).single.status, 200);
    });

    testFake('a restored user: sent without an identify first', (async, api) {
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 2));
      expect(api.of('identify-user'), hasLength(1));
      expect(_updates(api).single.body['userId'], api.expectedUserId('alice'));
    }, stored: savedUserStatic('alice'));

    testFake('a copy of the traits is sent', (async, api) {
      identify(async, 'alice');
      api.scenario.latency = const Duration(milliseconds: 300);
      final props = <String, dynamic>{'plan': 'pro'};
      Encatch.trackEvent('busy'); // the update queues behind this
      Encatch.setUserProperties('alice', UserTraits(set: props));
      props['plan'] = 'changed';
      async.elapse(const Duration(seconds: 3));
      expect((_updates(api).single.body['userAttributes'] as Map)[r'$set'], {
        'plan': 'pro',
      });
    }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);
  });

  group('ignored', () {
    testFake('a visitor: not-identified', (async, api) {
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 2));
      expect(api.requests, isEmpty);
      expect(_skips, ['identify-user not-identified']);
    }, onResponse: _onResponse);

    testFake('another user: wrong-user', (async, api) {
      identify(async, 'alice');
      Encatch.setUserProperties('bob', _pro);
      async.elapse(const Duration(seconds: 2));
      expect(_updates(api), isEmpty);
      expect(_skips, ['identify-user wrong-user']);
    }, onResponse: _onResponse);

    testFake(
      "switching A to B, pending: A's update is wrong-user, B's waits and "
      "goes after B's identify",
      (async, api) {
        identify(async, 'alice');
        api.scenario.latency = const Duration(milliseconds: 500);
        Encatch.identifyUser('bob');
        Encatch.setUserProperties('alice', _pro);
        Encatch.setUserProperties('bob', _pro);
        async.elapse(const Duration(seconds: 3));
        expect(_skips, ['identify-user wrong-user']);
        final update = _updates(api).single;
        expect(update.body['userName'], 'bob');
        expect(update.body['userId'], api.expectedUserId('bob'));
      },
      onResponse: _onResponse,
    );

    testFake("switching A to B, failed: B's update is not-identified", (
      async,
      api,
    ) {
      identify(async, 'alice');
      api.scenario.faults = [Fault('identify-user', status: 400)];
      Encatch.identifyUser('bob');
      Encatch.setUserProperties('bob', _pro);
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 3));
      expect(_updates(api), isEmpty);
      // alice's is decided at once; bob's after his identify fails.
      expect(_skips, [
        'identify-user wrong-user',
        'identify-user not-identified',
      ]);
    }, onResponse: _onResponse);

    testFake(
      "A, B pending, back to A whose identify fails: A's update is ignored",
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          // bob's identify is slow but succeeds; alice's next one fails.
          Fault('identify-user', delay: const Duration(milliseconds: 300)),
          Fault('identify-user', status: 400),
        ];
        Encatch.identifyUser('bob');
        async.flushMicrotasks();
        Encatch.identifyUser('alice');
        Encatch.setUserProperties('alice', _pro);
        async.elapse(const Duration(seconds: 3));
        expect(api.of('identify-user').map((r) => r.status), [200, 200, 400]);
        expect(_updates(api), isEmpty);
        expect(_skips, ['identify-user not-identified']);
      },
      onResponse: _onResponse,
    );

    testFake('empty or unsendable traits: no request, no throw', (async, api) {
      identify(async, 'alice');
      Object? thrown;
      void call(UserTraits t) => Encatch.setUserProperties(
        'alice',
        t,
      ).catchError((Object e) => thrown = e);
      call(const UserTraits());
      call(const UserTraits(set: {}, unset: []));
      call(UserTraits(set: {'n': BigInt.one}));
      call(const UserTraits(increment: {'n': double.nan}));
      async.elapse(const Duration(seconds: 2));
      expect(thrown, isNull);
      expect(_updates(api), isEmpty);
    });

    testFake('during a 429 pause: rate-limited', (async, api) {
      identify(async, 'alice');
      api.scenario.faults = [
        Fault('track-event', status: 429, retryAfterSeconds: 10),
      ];
      Encatch.trackEvent('starts-a-pause');
      async.elapse(const Duration(seconds: 1));
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 15));
      expect(_updates(api), isEmpty);
      expect(_skips, contains('identify-user rate-limited'));
    }, onResponse: _onResponse);

    testFake(
      'after a signature expiry: signature-expired',
      (async, api) {
        secureIdentify(async, api, 'alice', secureSessionApiKey);
        async.elapse(const Duration(minutes: 17));
        expect(api.requests.where((r) => r.status == 401), hasLength(1));
        Encatch.setUserProperties('alice', _pro);
        async.elapse(const Duration(seconds: 2));
        expect(_updates(api), isEmpty);
        expect(_skips, contains('identify-user signature-expired'));
      },
      apiKey: secureSessionApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
      onResponse: _onResponse,
    );
  });

  group('waiting', () {
    testFake(
      'waits for a held identify of the same user during a 429 pause, and '
      'goes after it',
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 5),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.identifyUser('bob'); // held
        Encatch.setUserProperties('bob', _pro);
        async.elapse(const Duration(seconds: 10));
        final all = api.of('identify-user').skip(1).toList();
        expect(all.map((r) => r.body['userName']), ['bob', 'bob']);
        expect(all.last.body['userId'], api.expectedUserId('bob'));
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake(
      'resetUser() is not held up while an update waits for a held identify',
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 10),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.identifyUser('bob'); // held
        Encatch.setUserProperties('bob', _pro);
        async.elapse(const Duration(seconds: 1));
        var reset = false;
        Encatch.resetUser().then((_) => reset = true);
        async.elapse(const Duration(seconds: 1));
        expect(reset, isTrue, reason: 'reset finished during the pause');

        async.elapse(const Duration(seconds: 15));
        expect(api.of('identify-user'), hasLength(1), reason: 'only alice');
        expect(_updates(api), isEmpty);
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake(
      'while an update waits for a held identify, a later identify still '
      'replaces the held one',
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 10),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.identifyUser('bob'); // held
        Encatch.setUserProperties('bob', _pro);
        Encatch.identifyUser('carol'); // replaces the held one
        async.elapse(const Duration(seconds: 15));
        final names = api.of('identify-user').map((r) => r.body['userName']);
        expect(names, ['alice', 'carol']);
        expect(_updates(api), isEmpty);
        expect(_skips, contains('identify-user wrong-user'));
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
      onResponse: _onResponse,
    );

    testFake('waits while a survey is open, then goes; a survey in its reply '
        'is shown', (async, api) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      Encatch.showForm(defaultFormId);
      async.elapse(const Duration(seconds: 1));
      expect(presenter.shown, hasLength(1));

      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 10));
      expect(_updates(api), isEmpty, reason: 'the survey is open');

      api.scenario.identifyTrigger = const SurveyTrigger(secondFormId);
      presenter.close();
      async.elapse(const Duration(seconds: 2));
      expect(_updates(api).single.status, 200);
      expect(presenter.shown.last.formId, secondFormId);
      presenter.dispose();
    });

    testFake('waits while an automatic show is pending', (async, api) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      api.scenario.screenTriggers = {
        '/later': const SurveyTrigger(defaultFormId, onPageDelay: 10),
      };
      Encatch.trackScreen('/later');
      async.elapse(const Duration(seconds: 2));
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 5));
      expect(_updates(api), isEmpty, reason: 'a survey is about to show');

      async.elapse(const Duration(seconds: 5));
      expect(presenter.shown, hasLength(1));
      presenter.close();
      async.elapse(const Duration(seconds: 2));
      expect(_updates(api), hasLength(1));
      presenter.dispose();
    });

    testFake('clearAll() while waiting for a survey: nothing sent', (
      async,
      api,
    ) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      Encatch.showForm(defaultFormId);
      async.elapse(const Duration(seconds: 1));
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 2));
      Encatch.clearAll();
      async.elapse(const Duration(seconds: 1));
      presenter.close();
      async.elapse(const Duration(seconds: 10));
      expect(_updates(api), isEmpty);
      presenter.dispose();
    });

    testFake('resetUser() while it is queued behind a slow request: not sent', (
      async,
      api,
    ) {
      identify(async, 'alice');
      api.scenario.faults = [
        Fault('track-event', delay: const Duration(seconds: 2), status: 200),
      ];
      Encatch.trackEvent('slow');
      async.flushMicrotasks();
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(milliseconds: 500));
      Encatch.resetUser();
      async.elapse(const Duration(seconds: 5));
      expect(_updates(api), isEmpty);
    });
  });

  group('effects', () {
    testFake('does not restart a stopped session or change isIdentified', (
      async,
      api,
    ) {
      identify(async, 'alice');
      Encatch.stopSession();
      async.flushMicrotasks();
      api.clearRequests();
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(minutes: 2));
      expect(_updates(api), hasLength(1));
      expect(api.count('ping'), 0);
      expect(Encatch.isIdentified, isTrue);
    });

    testFake("clears identify's traits memory: identify T, update U, identify "
        'T is sent; then an identify without traits is not', (async, api) {
      identify(async, 'alice');
      Encatch.identifyUser('alice', traits: _pro);
      async.elapse(const Duration(seconds: 1));
      Encatch.setUserProperties(
        'alice',
        const UserTraits(set: {'plan': 'team'}),
      );
      async.elapse(const Duration(seconds: 1));
      Encatch.identifyUser('alice', traits: _pro);
      async.elapse(const Duration(seconds: 1));
      Encatch.identifyUser('alice');
      async.elapse(const Duration(seconds: 1));
      expect(api.of('identify-user'), hasLength(4));
    });

    testFake('a reply arriving after resetUser() is ignored', (async, api) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      api.scenario
        ..latency = const Duration(seconds: 1)
        ..identifyTrigger = const SurveyTrigger(defaultFormId);
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(milliseconds: 500));
      Encatch.resetUser();
      async.elapse(const Duration(seconds: 3));
      expect(_updates(api).single.status, 200);
      expect(presenter.shown, isEmpty);
      presenter.dispose();
    });

    testFake(
      'a 401 with the stored session-time signature is a signature expiry',
      (async, api) {
        secureIdentify(async, api, 'alice', secureSessionApiKey);
        Encatch.pauseSession(); // no ping to find the expiry first
        async.elapse(const Duration(minutes: 17));
        expect(api.requests.where((r) => r.status == 401), isEmpty);

        Encatch.setUserProperties('alice', _pro);
        async.elapse(const Duration(seconds: 2));
        expect(_updates(api).single.status, 401);
        Encatch.trackEvent('after');
        async.elapse(const Duration(seconds: 2));
        expect(api.count('track-event'), 0);
        expect(_skips, contains('track-event signature-expired'));
      },
      apiKey: secureSessionApiKey,
      onResponse: _onResponse,
    );

    testFake(
      "a 401 for the previous user after resetUser() is not the visitor's "
      'expiry',
      (async, api) {
        secureIdentify(async, api, 'alice', secureSessionApiKey);
        Encatch.pauseSession();
        async.elapse(const Duration(minutes: 17));
        api.scenario.latency = const Duration(seconds: 1);
        Encatch.setUserProperties('alice', _pro);
        async.elapse(const Duration(milliseconds: 500));
        Encatch.resetUser();
        async.elapse(const Duration(seconds: 3));
        expect(_updates(api).single.status, 401);

        api.scenario.latency = Duration.zero;
        Encatch.trackEvent('as-a-visitor');
        async.elapse(const Duration(seconds: 2));
        expect(api.of('track-event').single.status, 200);
      },
      apiKey: secureSessionApiKey,
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake(r'$increment is not retried after a 500; $set is', (async, api) {
      identify(async, 'alice');
      api.scenario.faults = [Fault('identify-user', status: 500)];
      Encatch.setUserProperties('alice', const UserTraits(increment: {'n': 1}));
      async.elapse(const Duration(seconds: 10));
      expect(_updates(api).map((r) => r.status), [500]);

      api.clearRequests();
      api.scenario.faults = [Fault('identify-user', status: 500)];
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 10));
      expect(_updates(api).map((r) => r.status), [500, 200]);

      api.clearRequests();
      api.scenario.faults = [Fault('identify-user', status: 500)];
      Encatch.setUserProperties('alice', const UserTraits(decrement: {'n': 1}));
      async.elapse(const Duration(seconds: 10));
      expect(_updates(api).map((r) => r.status), [500]);
    });

    testFake('updates go out in call order: an older one retried after a 500 '
        'lands before a newer one', (async, api) {
      identify(async, 'alice');
      api.scenario.faults = [Fault('identify-user', status: 500)];
      Encatch.setUserProperties('alice', const UserTraits(set: {'v': 'old'}));
      Encatch.setUserProperties('alice', const UserTraits(set: {'v': 'new'}));
      async.elapse(const Duration(seconds: 15));
      final sent = _updates(api).map(
        (r) => '${(r.body['userAttributes'] as Map)[r'$set']['v']} ${r.status}',
      );
      expect(sent, ['old 500', 'old 200', 'new 200']);
    });
  });

  group('found in review', () {
    testFake('clearAll(), then identify and update, none awaited: the update '
        'is sent', (async, api) {
      identify(async, 'alice');
      Encatch.clearAll();
      Encatch.identifyUser('bob');
      Encatch.setUserProperties('bob', _pro);
      async.elapse(const Duration(seconds: 3));
      final update = _updates(api).single;
      expect(update.body['userName'], 'bob');
      expect(update.status, 200);
    });

    testFake(
      'a duplicate identify during a 429 pause does not let updates through: '
      'they are rate-limited',
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 10),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.identifyUser('alice'); // a duplicate
        for (var i = 0; i < 3; i++) {
          Encatch.setUserProperties('alice', _pro);
        }
        async.elapse(const Duration(seconds: 15));
        expect(_updates(api), isEmpty);
        expect(api.of('identify-user'), hasLength(1));
        expect(
          _skips.where((s) => s == 'identify-user rate-limited'),
          hasLength(3),
        );
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
      onResponse: _onResponse,
    );

    testFake('stop() at any moment during an update never blocks later '
        'updates', (async, api) {
      identify(async, 'alice');
      void after(int hops, void Function() f) =>
          hops == 0 ? f() : scheduleMicrotask(() => after(hops - 1, f));
      var expected = 0;
      for (var hops = 0; hops <= 40; hops++) {
        Encatch.setUserProperties('alice', UserTraits(set: {'round': hops}));
        after(hops, Encatch.stop);
        async.elapse(const Duration(seconds: 2));
        Encatch.setUserProperties('alice', UserTraits(set: {'after': hops}));
        async.elapse(const Duration(seconds: 2));
        expected++;
        final afterStop = _updates(api).where(
          (r) => ((r.body['userAttributes'] as Map)[r'$set'] as Map)
              .containsKey('after'),
        );
        expect(afterStop, hasLength(expected), reason: 'stop after $hops');
      }
    });

    testFake('a reply landing while resetUser() runs does not leave the user '
        'confirmed: an update after a failed identify is ignored', (
      async,
      api,
    ) {
      void after(int hops, void Function() f) =>
          hops == 0 ? f() : scheduleMicrotask(() => after(hops - 1, f));
      for (var hops = 0; hops <= 12; hops++) {
        Encatch.identifyUser('alice');
        after(hops, Encatch.resetUser);
        async.elapse(const Duration(seconds: 2));
        expect(Encatch.userName, isNull, reason: 'reset after $hops');

        api.scenario.faults = [Fault('identify-user', status: 400)];
        Encatch.identifyUser('alice');
        Encatch.setUserProperties('alice', _pro);
        async.elapse(const Duration(seconds: 2));
        expect(_updates(api), isEmpty, reason: 'reset after $hops');
        Encatch.resetUser();
        async.elapse(const Duration(seconds: 1));
      }
    });

    testFake('resetUser() then identifyUser(), not awaited, during a 429 '
        'pause: the identify is kept and sent after the pause', (async, api) {
      identify(async, 'alice');
      api.scenario.faults = [
        Fault('track-event', status: 429, retryAfterSeconds: 5),
      ];
      Encatch.trackEvent('starts-a-pause');
      async.elapse(const Duration(seconds: 1));
      Encatch.resetUser();
      Encatch.identifyUser('bob');
      async.elapse(const Duration(seconds: 10));
      expect(api.of('identify-user').map((r) => r.body['userName']), [
        'alice',
        'bob',
      ]);
      expect(Encatch.userName, 'bob');
    }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

    testFake(
      'clearAll(), then identify and update during a 429 pause: the identify '
      'is sent at once (clearAll ends the pause), then the update',
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 30),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.clearAll();
        Encatch.identifyUser('bob');
        Encatch.setUserProperties('bob', _pro);
        async.elapse(const Duration(seconds: 3));
        expect(Encatch.userName, 'bob');
        expect(_updates(api).single.body['userName'], 'bob');

        // Nothing comes back later as bob after the user changes.
        Encatch.identifyUser('carol');
        async.elapse(const Duration(minutes: 2));
        expect(Encatch.userName, 'carol');
        expect(api.of('identify-user').last.body['userName'], 'carol');
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake(
      'held bob, then alice again during a 429 pause: alice\'s updates are '
      'rate-limited',
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 10),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.identifyUser('bob');
        Encatch.identifyUser('alice');
        for (var i = 0; i < 3; i++) {
          Encatch.setUserProperties('alice', _pro);
        }
        async.elapse(const Duration(seconds: 15));
        expect(_updates(api), isEmpty);
        expect(
          _skips.where((s) => s == 'identify-user rate-limited'),
          hasLength(3),
        );
        expect(Encatch.userName, 'alice');
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
      onResponse: _onResponse,
    );

    testFake(
      'resetUser() then identifyUser() for the same user during a 429 pause: '
      'the identify is sent after the pause',
      (async, api) {
        identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 5),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.resetUser();
        Encatch.identifyUser('alice');
        async.elapse(const Duration(seconds: 10));
        expect(api.of('identify-user'), hasLength(2));
        expect(Encatch.userName, 'alice');
        expect(Encatch.isIdentified, isTrue);
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake('stop() while an update waits for a survey: not sent', (
      async,
      api,
    ) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      Encatch.showForm(defaultFormId);
      async.elapse(const Duration(seconds: 1));
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 2));
      Encatch.stop();
      presenter.close();
      async.elapse(const Duration(seconds: 10));
      expect(_updates(api), isEmpty);
      presenter.dispose();
    });

    testFake('a survey that opens after the update is queued: sent after it '
        'closes', (async, api) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      api.scenario.faults = [
        Fault('track-event', delay: const Duration(seconds: 2), status: 200),
      ];
      Encatch.trackEvent('slow');
      async.flushMicrotasks();
      Encatch.setUserProperties('alice', _pro); // queued behind the event
      async.elapse(const Duration(milliseconds: 500));
      Encatch.showForm(defaultFormId);
      async.elapse(const Duration(seconds: 5));
      expect(presenter.shown, hasLength(1));
      expect(_updates(api), isEmpty, reason: 'the survey is open');

      presenter.close();
      async.elapse(const Duration(seconds: 3));
      expect(_updates(api), hasLength(1));
      presenter.dispose();
    });
  });

  group('logging', () {
    testFake('warnings appear without debug mode; debug lines do not', (
      async,
      api,
    ) {
      final lines = <String>[];
      EncatchLogger.sink = (output, _) => lines.add(output);
      Encatch.setUserProperties('alice', _pro); // visitor: debug
      identify(async, 'alice');
      Encatch.setUserProperties('bob', _pro); // wrong user: warning
      async.elapse(const Duration(seconds: 1));
      expect(lines.where((l) => l.contains('no user is identified')), isEmpty);
      expect(
        lines.where(
          (l) => l.contains(
            'setUserProperties("bob") ignored: the current user is "alice".',
          ),
        ),
        hasLength(1),
      );
    });

    testFake('with debug mode the visitor message appears', (async, api) {
      final lines = <String>[];
      EncatchLogger.sink = (output, _) => lines.add(output);
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 1));
      expect(
        lines.where(
          (l) => l.contains(
            'setUserProperties ignored: no user is identified. Call '
            'identifyUser() first.',
          ),
        ),
        hasLength(1),
      );
    }, debugMode: true);
  });
}

/// What an earlier run saved for an identified [userName], for `stored:`.
Map<String, Object> savedUserStatic(String userName) =>
    savedUser(FakeApi(), userName);
