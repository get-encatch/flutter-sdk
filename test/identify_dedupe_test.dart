// identifyUser() dedupe, as in React Native 1.5.0-beta.2: after the first
// identify of an app run, a repeat for the same user with the same traits, or
// none, is not sent. Use setUserProperties() to update properties on purpose.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/logger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';
import 'secure_identify_test.dart' show secureIdentify;

/// `endpoint reason` for every call the SDK reported as skipped.
final _skips = <String>[];
void _onResponse(EncatchResponseInfo info) {
  if (info.outcome == 'skipped') _skips.add('${info.endpoint} ${info.reason}');
}

List<FakeRequest> _identifies(FakeApi api) => api.of('identify-user');

void _identify(
  FakeAsync async,
  String userName, {
  UserTraits? traits,
  IdentifyOptions? options,
}) {
  Encatch.identifyUser(userName, traits: traits, options: options);
  async.elapse(const Duration(seconds: 1));
}

/// A value JSON can't carry and that has no toJson.
class _NotJson {}

/// A value whose toJson gives something JSON can carry.
class _Plan {
  _Plan(this.name);
  final String name;
  Map<String, dynamic> toJson() => {'plan': name};
}

/// A map that contains itself.
Map<String, Object?> _circular() {
  final map = <String, Object?>{};
  map['self'] = map;
  return map;
}

/// A value whose toJson gives something JSON can't carry.
class _BadJson {
  Object toJson() => BigInt.one;
}

void main() {
  setUp(_skips.clear);
  tearDown(() => EncatchLogger.sink = null);

  group('sent or not', () {
    testFake(
      'a restored user: the first identify of the run is sent, a second not',
      (async, api) {
        _identify(async, 'alice');
        _identify(async, 'alice');
        expect(_identifies(api), hasLength(1));
        expect(_skips, ['identify-user duplicate']);
      },
      stored: {
        'encatch_user_name': 'alice',
        'encatch_user_id_alice': '9b2f5e9e-0000-5000-8000-000000000001',
      },
      onResponse: _onResponse,
    );

    testFake('the same user with no traits after traits: not sent', (
      async,
      api,
    ) {
      _identify(async, 'alice', traits: const UserTraits(set: {'plan': 'pro'}));
      _identify(async, 'alice');
      expect(_identifies(api), hasLength(1));
    });

    testFake(
      'the same traits in another key order or \$unset order: not sent, and '
      "the caller's list is not reordered",
      (async, api) {
        _identify(
          async,
          'alice',
          traits: const UserTraits(set: {'a': 1, 'b': 2}, unset: ['x', 'y']),
        );
        final unset = ['y', 'x'];
        _identify(
          async,
          'alice',
          traits: UserTraits(set: const {'b': 2, 'a': 1}, unset: unset),
        );
        expect(_identifies(api), hasLength(1));
        expect(unset, ['y', 'x']);
      },
    );

    testFake('nested maps compare by content, not key order', (async, api) {
      _identify(
        async,
        'alice',
        traits: const UserTraits(
          set: {
            'address': {'city': 'Pune', 'zip': '411001'},
          },
        ),
      );
      _identify(
        async,
        'alice',
        traits: const UserTraits(
          set: {
            'address': {'zip': '411001', 'city': 'Pune'},
          },
        ),
      );
      expect(_identifies(api), hasLength(1));
    });

    testFake('empty operations count as no traits', (async, api) {
      _identify(async, 'alice');
      _identify(
        async,
        'alice',
        traits: const UserTraits(set: {}, setOnce: {}, unset: []),
      );
      expect(_identifies(api), hasLength(1));
    });

    testFake('traits A, B, A: three sent; users A, B, A: three sent', (
      async,
      api,
    ) {
      const a = UserTraits(set: {'plan': 'free'});
      const b = UserTraits(set: {'plan': 'pro'});
      _identify(async, 'alice', traits: a);
      _identify(async, 'alice', traits: b);
      _identify(async, 'alice', traits: a);
      expect(_identifies(api), hasLength(3));

      api.clearRequests();
      _identify(async, 'bob');
      _identify(async, 'alice');
      _identify(async, 'bob');
      expect(_identifies(api).map((r) => r.body['userName']), [
        'bob',
        'alice',
        'bob',
      ]);
    });

    testFake('a burst of 20 during a switch sends one', (async, api) {
      _identify(async, 'alice');
      api.scenario.latency = const Duration(milliseconds: 200);
      for (var i = 0; i < 20; i++) {
        Encatch.identifyUser('bob');
      }
      async.elapse(const Duration(seconds: 5));
      expect(_identifies(api).map((r) => r.body['userName']), ['alice', 'bob']);
    });

    testFake('repeats during a 429 pause: one sent', (async, api) {
      _identify(async, 'alice');
      api.scenario.faults = [
        Fault('track-event', status: 429, retryAfterSeconds: 10),
      ];
      Encatch.trackEvent('starts-a-pause');
      async.elapse(const Duration(seconds: 1));
      for (var i = 0; i < 20; i++) {
        Encatch.identifyUser(
          'alice',
          traits: const UserTraits(set: {'plan': 'pro'}),
        );
      }
      async.elapse(const Duration(seconds: 15));
      expect(_identifies(api), hasLength(2));
    }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

    testFake('the same \$increment twice: the second is not sent', (
      async,
      api,
    ) {
      _identify(
        async,
        'alice',
        traits: const UserTraits(increment: {'logins': 1}),
      );
      _identify(
        async,
        'alice',
        traits: const UserTraits(increment: {'logins': 1}),
      );
      expect(_identifies(api), hasLength(1));
    }, onResponse: _onResponse);

    testFake('a fresh signature is sent; the same one repeated is not; secure '
        'omitted afterwards is sent', (async, api) {
      secureIdentify(async, api, 'alice', secureSessionApiKey);
      async.elapse(const Duration(seconds: 2));
      final signed = api.sign('alice', secureSessionApiKey);
      final again = IdentifyOptions(
        secure: SecureOptions(
          signature: signed.signature,
          generatedDateTimeinUTC: signed.time,
        ),
      );
      api.scenario.latency = const Duration(milliseconds: 500);
      Encatch.identifyUser('alice', options: again);
      Encatch.identifyUser('alice', options: again); // while in flight
      async.elapse(const Duration(seconds: 2));
      expect(_identifies(api), hasLength(2));

      _identify(async, 'alice');
      expect(_identifies(api), hasLength(3));
    }, apiKey: secureSessionApiKey);

    testFake('locale and country: compared with what the last identify '
        'carried', (async, api) {
      _identify(async, 'alice', options: const IdentifyOptions(locale: 'fr'));
      _identify(async, 'alice', options: const IdentifyOptions(locale: 'fr'));
      expect(_identifies(api), hasLength(1), reason: 'same locale');

      _identify(async, 'alice', options: const IdentifyOptions(locale: 'de'));
      _identify(async, 'alice', options: const IdentifyOptions(locale: 'de'));
      expect(_identifies(api), hasLength(2), reason: 'different, then same');

      _identify(async, 'alice', options: const IdentifyOptions(country: 'IN'));
      _identify(async, 'alice', options: const IdentifyOptions(country: 'IN'));
      expect(_identifies(api), hasLength(3));

      // Not given: not compared.
      _identify(async, 'alice');
      expect(_identifies(api), hasLength(3));
    });

    testFake("setLocale('fr') then an identify with locale fr is sent", (
      async,
      api,
    ) {
      _identify(async, 'alice');
      Encatch.setLocale('fr');
      _identify(async, 'alice', options: const IdentifyOptions(locale: 'fr'));
      expect(_identifies(api), hasLength(2));
    });

    testFake(
      'after a signature expiry the same identify is sent once',
      (async, api) {
        secureIdentify(async, api, 'alice', secureSessionApiKey);
        async.elapse(const Duration(minutes: 17));
        expect(api.requests.where((r) => r.status == 401), hasLength(1));

        api.clearRequests();
        // The app's stale signature: the same as the last identify carried.
        final stale = _identifies(api);
        expect(stale, isEmpty);
        final signed = api.sign('alice', secureSessionApiKey);
        final fresh = IdentifyOptions(
          secure: SecureOptions(
            signature: signed.signature,
            generatedDateTimeinUTC: signed.time,
          ),
        );
        for (var i = 0; i < 20; i++) {
          Encatch.identifyUser('alice', options: fresh);
        }
        async.elapse(const Duration(seconds: 3));
        expect(_identifies(api).map((r) => r.status), [200]);
      },
      apiKey: secureSessionApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );

    testFake(
      'after a signature expiry, the identical identify (same signature) is '
      'sent once too',
      (async, api) {
        final signed = api.sign('alice', secureSessionApiKey);
        final options = IdentifyOptions(
          secure: SecureOptions(
            signature: signed.signature,
            generatedDateTimeinUTC: signed.time,
          ),
        );
        _identify(async, 'alice', options: options);
        async.elapse(const Duration(minutes: 17));
        expect(api.requests.where((r) => r.status == 401), hasLength(1));

        api.clearRequests();
        for (var i = 0; i < 5; i++) {
          Encatch.identifyUser('alice', options: options);
        }
        async.elapse(const Duration(seconds: 3));
        expect(_identifies(api), hasLength(1));
      },
      apiKey: secureSessionApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );

    testFake('after stopSession() the identify is sent and the session is on '
        'again; 20 repeats send one', (async, api) {
      _identify(async, 'alice');
      Encatch.stopSession();
      async.flushMicrotasks();
      api.clearRequests();

      for (var i = 0; i < 20; i++) {
        Encatch.identifyUser('alice');
      }
      async.elapse(const Duration(seconds: 40));
      expect(_identifies(api), hasLength(1));
      expect(api.count('ping'), greaterThanOrEqualTo(1));
    });

    testFake('a 429-dropped identify can be sent again', (async, api) {
      api.scenario.faults = [
        Fault('identify-user', status: 429, retryAfterSeconds: 1),
      ];
      _identify(async, 'alice');
      async.elapse(const Duration(seconds: 2));
      _identify(async, 'alice');
      expect(_identifies(api).map((r) => r.status), [429, 200]);
    });

    testFake('a failed identify with traits clears them even after a later '
        'identify without traits was sent', (async, api) {
      _identify(async, 'alice');
      api.scenario.faults = [
        Fault(
          'identify-user',
          status: 400,
          delay: const Duration(milliseconds: 500),
        ),
      ];
      const t1 = UserTraits(set: {'plan': 'pro'});
      Encatch.identifyUser('alice', traits: t1);
      async.flushMicrotasks();
      // Sent (locale changed) while the one with traits is still in flight.
      Encatch.identifyUser(
        'alice',
        options: const IdentifyOptions(locale: 'fr'),
      );
      async.elapse(const Duration(seconds: 3));
      expect(_identifies(api).map((r) => r.status), [200, 400, 200]);

      _identify(async, 'alice', traits: t1);
      expect(_identifies(api).map((r) => r.status), [200, 400, 200, 200]);
    });

    testFake(
      'held during a 429 pause and replaced: the traits of the replaced one '
      'were never sent',
      (async, api) {
        _identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 5),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        const t1 = UserTraits(set: {'plan': 'pro'});
        Encatch.identifyUser('alice', traits: t1);
        Encatch.identifyUser(
          'alice',
          options: const IdentifyOptions(locale: 'fr'),
        );
        async.elapse(const Duration(seconds: 10));
        expect(_identifies(api), hasLength(2));
        expect(_identifies(api).last.body['userAttributes'], isNull);

        _identify(async, 'alice', traits: t1);
        expect(_identifies(api), hasLength(3));
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake(
      'held during a 429 pause: a plain identify after one with traits does '
      'not replace it, and the traits are sent',
      (async, api) {
        _identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 5),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.identifyUser(
          'alice',
          traits: const UserTraits(set: {'plan': 'pro'}),
        );
        Encatch.identifyUser('alice');
        async.elapse(const Duration(seconds: 10));
        expect(_identifies(api), hasLength(2));
        expect(_identifies(api).last.body['userAttributes'], {
          r'$set': {'plan': 'pro'},
        });
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake(
      'held during a 429 pause: a different user, then the current one again, '
      'ends as the current one',
      (async, api) {
        _identify(async, 'alice');
        api.scenario.faults = [
          Fault('track-event', status: 429, retryAfterSeconds: 5),
        ];
        Encatch.trackEvent('starts-a-pause');
        async.elapse(const Duration(seconds: 1));
        Encatch.identifyUser('bob');
        Encatch.identifyUser('alice');
        async.elapse(const Duration(seconds: 10));
        expect(Encatch.userName, 'alice');
        expect(_identifies(api).map((r) => r.body['userName']), ['alice']);
      },
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake('held during a 429 pause: traits, then a locale, then the traits '
        'again: the last call is sent with its traits', (async, api) {
      _identify(async, 'alice');
      api.scenario.faults = [
        Fault('track-event', status: 429, retryAfterSeconds: 5),
      ];
      Encatch.trackEvent('starts-a-pause');
      async.elapse(const Duration(seconds: 1));
      const pro = UserTraits(set: {'plan': 'pro'});
      Encatch.identifyUser('alice', traits: pro);
      Encatch.identifyUser(
        'alice',
        options: const IdentifyOptions(locale: 'de'),
      );
      Encatch.identifyUser('alice', traits: pro);
      async.elapse(const Duration(seconds: 10));
      expect(_identifies(api), hasLength(2));
      expect(_identifies(api).last.body['userAttributes'], {
        r'$set': {'plan': 'pro'},
      });
    }, configure: (api) => api.scenario.allowTrackEventForVisitors = true);

    testFake('a skipped call changes no memory: T1, none, T1 sends one', (
      async,
      api,
    ) {
      const t1 = UserTraits(set: {'plan': 'pro'});
      _identify(async, 'alice', traits: t1);
      _identify(async, 'alice');
      _identify(async, 'alice', traits: t1);
      expect(_identifies(api), hasLength(1));
    });

    testFake('resetUser() clears the memory', (async, api) {
      _identify(async, 'alice');
      Encatch.resetUser();
      async.flushMicrotasks();
      _identify(async, 'alice');
      expect(_identifies(api), hasLength(2));
    });

    testFake('clearAll() clears the memory', (async, api) {
      _identify(async, 'alice');
      Encatch.clearAll();
      async.flushMicrotasks();
      _identify(async, 'alice');
      expect(_identifies(api), hasLength(2));
    });
  });

  group('traits a request cannot carry', () {
    for (final (what, value) in <(String, Object Function())>[
      ('a BigInt', () => BigInt.two),
      ('NaN', () => double.nan),
      ('an object without toJson', _NotJson.new),
      ('an object whose toJson gives a BigInt', _BadJson.new),
      ('a date inside a list', () => [DateTime(2026)]),
      ('a circular map', _circular),
    ]) {
      testFake('$what: no request, no throw, a warning', (async, api) {
        final lines = <String>[];
        EncatchLogger.sink = (output, _) => lines.add(output);
        Object? thrown;
        Encatch.identifyUser(
          'alice',
          traits: UserTraits(set: {'x': value()}),
        ).catchError((Object e) => thrown = e);
        async.elapse(const Duration(seconds: 3));
        expect(thrown, isNull);
        expect(api.requests, isEmpty);
        expect(
          lines.where((l) => l.contains("can't be sent")),
          hasLength(1),
          reason: lines.join('\n'),
        );
      });
    }

    testFake('a value with a toJson is sent as JSON sends it', (async, api) {
      _identify(async, 'alice', traits: UserTraits(set: {'p': _Plan('pro')}));
      expect(_identifies(api).single.body['userAttributes'], {
        r'$set': {
          'p': {'plan': 'pro'},
        },
      });
      _identify(async, 'alice', traits: UserTraits(set: {'p': _Plan('pro')}));
      expect(_identifies(api), hasLength(1), reason: 'same as JSON');
    });

    testFake('dates in \$set are sent as ISO strings', (async, api) {
      final at = DateTime.utc(2026, 11, 27, 10);
      _identify(async, 'alice', traits: UserTraits(set: {'since': at}));
      expect((_identifies(api).single.body['userAttributes'] as Map)[r'$set'], {
        'since': at.toIso8601String(),
      });
    });
  });

  group('logging and reporting', () {
    testFake(
      'with debug mode the duplicate message names setUserProperties',
      (async, api) {
        final lines = <String>[];
        EncatchLogger.sink = (output, _) => lines.add(output);
        _identify(async, 'alice');
        _identify(async, 'alice');
        expect(
          lines.where(
            (l) =>
                l.contains('identifyUser "alice" skipped') &&
                l.contains('setUserProperties("alice", traits)'),
          ),
          hasLength(1),
          reason: lines.join('\n'),
        );
        expect(_skips, ['identify-user duplicate']);
      },
      debugMode: true,
      onResponse: _onResponse,
    );

    testFake('without debug mode nothing is logged', (async, api) {
      final lines = <String>[];
      EncatchLogger.sink = (output, _) => lines.add(output);
      _identify(async, 'alice');
      _identify(async, 'alice');
      expect(lines.where((l) => l.contains('skipped')), isEmpty);
    });
  });
}
