// EncatchConfig.onSignatureExpired, and which 401s count as an expired secure
// signature (as in React Native 1.5.0-beta.3).
import 'dart:async';

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/logger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

const _key = secureSessionApiKey;

const _submit = SubmitFormRequest(
  triggerType: TriggerType.manual,
  formDetails: FormDetails(
    formConfigurationId: defaultFormId,
    isPartialSubmit: false,
  ),
);

const _pro = UserTraits(set: {'plan': 'pro'});

/// Users onSignatureExpired was called for, in order.
final _calls = <String>[];

/// What the test's onSignatureExpired does after recording the call.
FutureOr<void> Function(String userName)? _then;

FutureOr<void> _hook(SignatureExpiredInfo info) {
  _calls.add(info.userName);
  return _then?.call(info.userName);
}

/// Identifies [userName] with a signature [age] old.
void _identify(
  FakeAsync async,
  FakeApi api,
  String userName, {
  Duration age = Duration.zero,
}) {
  final signed = api.sign(userName, _key, age: age);
  Encatch.identifyUser(
    userName,
    options: IdentifyOptions(
      secure: SecureOptions(
        signature: signed.signature,
        generatedDateTimeinUTC: signed.time,
      ),
    ),
  );
  async.elapse(const Duration(seconds: 2));
}

const _stale = Duration(minutes: 20);

/// alice signed in, then her stored signature found expired by
/// setUserProperties (the gateway checks the signature on identify-user only).
void _expireStored(FakeAsync async, FakeApi api) {
  _identify(async, api, 'alice');
  expect(api.of('identify-user').last.status, 200);
  async.elapse(const Duration(minutes: 17));
  Encatch.setUserProperties('alice', _pro);
  async.elapse(const Duration(seconds: 2));
  expect(api.of('identify-user').last.status, 401);
}

int _eventsAfter(FakeApi api, int from) =>
    api.requests.skip(from).where((r) => r.endpoint == 'track-event').length;

void _testExpiry(
  String description,
  void Function(FakeAsync async, FakeApi api) body, {
  void Function(FakeApi api)? configure,
  bool callback = true,
  void Function(EncatchResponseInfo info)? onResponse,
}) => testFake(
  description,
  body,
  apiKey: _key,
  configure: configure,
  onResponse: onResponse,
  onSignatureExpired: callback ? _hook : null,
);

void main() {
  final lines = <String>[];
  setUp(() {
    _calls.clear();
    _then = null;
    lines.clear();
    EncatchLogger.sink = (output, _) => lines.add(output);
  });
  tearDown(() => EncatchLogger.sink = null);

  List<String> warnings() => lines.where((l) => l.contains('WARN')).toList();

  group('the stored signature', () {
    _testExpiry('found expired by setUserProperties: called once; the '
        'expired state holds a submit until a fresh identify', (async, api) {
      _expireStored(async, api);
      expect(_calls, ['alice']);
      expect(
        warnings().where((l) => l.contains('signature expired (401)')),
        hasLength(1),
      );

      // The expired state: background traffic stops, a submit is held.
      api.clearRequests();
      Encatch.trackEvent('while-expired');
      var submitted = false;
      Encatch.submitForm(_submit).then((_) => submitted = true);
      async.elapse(const Duration(minutes: 2));
      expect(api.count('track-event'), 0);
      expect(api.count('submit-form'), 0);
      expect(submitted, isTrue, reason: 'held, not waiting on the app');

      _identify(async, api, 'alice');
      expect(api.of('identify-user').last.status, 200);
      expect(api.of('submit-form').single.status, 200);
      expect(_calls, ['alice'], reason: 'not called again');
      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      expect(api.of('track-event').single.status, 200);
    });

    _testExpiry('an older gateway (no reason): a 401 on setUserProperties '
        'with the stored signature still counts', (async, api) {
      _expireStored(async, api);
      expect(api.of('identify-user').last.reply?['reason'], isNull);
      expect(_calls, ['alice']);
      final from = api.requests.length;
      Encatch.trackEvent('while-expired');
      async.elapse(const Duration(seconds: 2));
      expect(_eventsAfter(api, from), 0);
    }, configure: (api) => api.scenario.expiredSignatureReason = false);

    _testExpiry(
      'the reason on another request (a gateway that checks every request) '
      'counts',
      (async, api) {
        _identify(async, api, 'alice');
        async.elapse(const Duration(minutes: 17));
        final rejected = api.requests.where((r) => r.status == 401).toList();
        expect(rejected, hasLength(1));
        expect(rejected.single.endpoint, isNot('identify-user'));
        expect(_calls, ['alice']);
      },
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );

    _testExpiry('a 401 without the reason on another request is not an '
        'expiry', (async, api) {
      _identify(async, api, 'alice');
      api.scenario.faults.add(
        Fault('track-event', status: 401, body: {'error': 'invalid api key'}),
      );
      Encatch.trackEvent('one');
      async.elapse(const Duration(seconds: 2));
      Encatch.trackEvent('two');
      async.elapse(const Duration(seconds: 2));
      expect(api.of('track-event').map((r) => r.status), [401, 200]);
      expect(_calls, isEmpty);
      expect(warnings().where((l) => l.contains('expired')), isEmpty);
    });

    _testExpiry('a 401 without the reason on another request carrying the '
        'stored timed signature is not an expiry either', (async, api) {
      _identify(async, api, 'alice');
      async.elapse(const Duration(minutes: 17));
      api.scenario.faults.add(Fault('track-event', status: 401));
      Encatch.trackEvent('one');
      async.elapse(const Duration(seconds: 2));
      Encatch.trackEvent('two');
      async.elapse(const Duration(seconds: 2));
      expect(api.of('track-event').map((r) => r.status), [401, 200]);
      expect(_calls, isEmpty);
    });

    _testExpiry('an expiry reply for a user who has since been reset is '
        'ignored', (async, api) {
      _identify(async, api, 'alice');
      async.elapse(const Duration(minutes: 17));
      api.scenario.faults.add(
        Fault('identify-user', delay: const Duration(seconds: 5)),
      );
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 1));
      Encatch.resetUser();
      async.elapse(const Duration(seconds: 10));
      expect(api.of('identify-user').last.status, 401);
      expect(_calls, isEmpty);
      expect(warnings().where((l) => l.contains('expired')), isEmpty);
    });

    _testExpiry(
      'a late expiry reply for a signature since replaced is ignored',
      (async, api) {
        _identify(async, api, 'alice');
        async.elapse(const Duration(minutes: 15, seconds: 45));
        // The next ping is slow (under the SDK's 30 s timeout): by the time
        // the gateway checks it, its signature has expired.
        api.scenario.faults.add(
          Fault('ping', delay: const Duration(seconds: 25)),
        );
        final pings = api.count('ping');
        while (api.count('ping') == pings) {
          async.elapse(const Duration(seconds: 1));
        }
        // Meanwhile the app identifies with a fresh signature.
        _identify(async, api, 'alice');
        expect(api.of('identify-user').last.status, 200);
        async.elapse(const Duration(minutes: 2));
        expect(
          api.requests.where((r) => r.status == 401).map((r) => r.endpoint),
          ['ping'],
        );
        expect(
          api.of('ping').firstWhere((r) => r.status == 401).reply?['reason'],
          'user_signature_expired',
        );
        expect(_calls, isEmpty);
        final from = api.requests.length;
        Encatch.trackEvent('after');
        async.elapse(const Duration(seconds: 2));
        expect(_eventsAfter(api, from), 1);
      },
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );
  });

  group("the app's own new signature", () {
    _testExpiry('already expired: called once; not the expired state', (
      async,
      api,
    ) {
      _identify(async, api, 'alice', age: _stale);
      final rejected = api.of('identify-user').single;
      expect(rejected.status, 401);
      expect(rejected.reply?['reason'], 'user_signature_expired');
      expect(_calls, ['alice']);
      expect(warnings(), hasLength(1));
      expect(warnings().single, contains('identifyUser("alice") rejected'));

      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      expect(api.count('track-event'), 1, reason: 'tracking goes on');
    });

    _testExpiry('a stale signature for the signed-in user: the stored one is '
        'kept', (async, api) {
      _identify(async, api, 'alice');
      final valid = api.of('identify-user').single.headers['x-user-signature'];
      _identify(async, api, 'alice', age: _stale);
      expect(api.of('identify-user').last.status, 401);
      expect(_calls, ['alice']);

      api.clearRequests();
      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      final event = api.of('track-event').single;
      expect(event.status, 200);
      expect(event.headers['x-user-signature'], valid);
      expect(event.headers['x-user-name'], 'alice');
    });

    _testExpiry('a switch to another user with a stale signature: called for '
        'the new user; tracking goes on', (async, api) {
      _identify(async, api, 'alice');
      _identify(async, api, 'bob', age: _stale);
      expect(_calls, ['bob']);
      final from = api.requests.length;
      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      expect(_eventsAfter(api, from), 1);
    });

    _testExpiry('rejected without the reason (a wrong signature): not called, '
        'not the expired state', (async, api) {
      Encatch.identifyUser(
        'alice',
        options: IdentifyOptions(
          secure: SecureOptions(
            signature: 'wrong',
            generatedDateTimeinUTC: '${DateTime.now().millisecondsSinceEpoch}',
          ),
        ),
      );
      async.elapse(const Duration(seconds: 2));
      expect(api.of('identify-user').single.status, 401);
      expect(_calls, isEmpty);
      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      expect(api.count('track-event'), 1);
    });

    _testExpiry('a signature that keeps being rejected: called once, no loop; '
        'after a successful identify a later expiry calls again', (async, api) {
      // The app's server keeps returning a stale signature.
      // Bounded, so a loop fails the test instead of hanging it.
      _then = (user) {
        if (_calls.length < 5) _identify(async, api, user, age: _stale);
      };
      _identify(async, api, 'alice', age: _stale);
      async.elapse(const Duration(minutes: 1));
      expect(_calls, ['alice']);
      expect(api.count('identify-user'), 2);

      _then = null;
      _identify(async, api, 'alice');
      expect(api.of('identify-user').last.status, 200);
      _identify(async, api, 'alice', age: _stale);
      expect(_calls, ['alice', 'alice']);
    });
  });

  group('the callback', () {
    _testExpiry('identifying again from it, after a delay: the held submit '
        'goes out and the state ends', (async, api) {
      _then = (user) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        final signed = api.sign(user, _key);
        Encatch.identifyUser(
          user,
          options: IdentifyOptions(
            secure: SecureOptions(
              signature: signed.signature,
              generatedDateTimeinUTC: signed.time,
            ),
          ),
        );
      };
      _expireStored(async, api);
      Encatch.submitForm(_submit);
      async.flushMicrotasks();
      expect(api.count('submit-form'), 0);
      async.elapse(const Duration(seconds: 10));
      expect(api.of('identify-user').last.status, 200);
      expect(api.of('submit-form').single.status, 200);
      final from = api.requests.length;
      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      expect(_eventsAfter(api, from), 1);
      expect(_calls, ['alice']);
    });

    _testExpiry('once per expiry: a fresh signature still rejected does not '
        'call again; after success a new expiry does', (async, api) {
      _expireStored(async, api);
      expect(_calls, ['alice']);
      _identify(async, api, 'alice', age: _stale);
      expect(api.of('identify-user').last.status, 401);
      expect(_calls, ['alice']);

      _identify(async, api, 'alice');
      expect(api.of('identify-user').last.status, 200);
      async.elapse(const Duration(minutes: 17));
      Encatch.setUserProperties('alice', _pro);
      async.elapse(const Duration(seconds: 2));
      expect(api.of('identify-user').last.status, 401);
      expect(_calls, ['alice', 'alice']);
    });

    _testExpiry('clearAll() before it runs: not called', (async, api) {
      _identify(async, api, 'alice');
      async.elapse(const Duration(minutes: 17));
      Encatch.setUserProperties('alice', _pro);
      // Run up to the reply, without letting timers fire.
      for (var i = 0; i < 50 && api.count('identify-user') < 2; i++) {
        async.flushMicrotasks();
      }
      expect(api.of('identify-user').last.status, 401);
      async.flushMicrotasks();
      Encatch.clearAll();
      async.elapse(const Duration(seconds: 5));
      expect(_calls, isEmpty);
    });

    _testExpiry('resetUser() before it runs: not called', (async, api) {
      _identify(async, api, 'alice', age: _stale);
      // _identify let it run; this time reset first.
      _calls.clear();
      _identify(async, api, 'alice');
      _identify(async, api, 'bob');
      final signed = api.sign('carol', _key, age: _stale);
      Encatch.identifyUser(
        'carol',
        options: IdentifyOptions(
          secure: SecureOptions(
            signature: signed.signature,
            generatedDateTimeinUTC: signed.time,
          ),
        ),
      );
      for (
        var i = 0;
        i < 50 && api.of('identify-user').last.body['userName'] != 'carol';
        i++
      ) {
        async.flushMicrotasks();
      }
      async.flushMicrotasks();
      expect(api.of('identify-user').last.status, 401);
      Encatch.resetUser();
      async.elapse(const Duration(seconds: 5));
      expect(_calls, isEmpty);
    });

    _testExpiry('one that throws: the SDK carries on', (async, api) {
      _then = (_) => throw StateError('app bug');
      _expireStored(async, api);
      expect(_calls, ['alice']);
      _identify(async, api, 'alice');
      expect(api.of('identify-user').last.status, 200);
      final from = api.requests.length;
      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      expect(_eventsAfter(api, from), 1);
    });

    _testExpiry('one whose Future fails: the SDK carries on', (async, api) {
      _then = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw StateError('backend down');
      };
      _expireStored(async, api);
      async.elapse(const Duration(seconds: 1));
      expect(_calls, ['alice']);
      _identify(async, api, 'alice');
      expect(api.of('identify-user').last.status, 200);
    });

    _testExpiry('none configured: one warning; waits for a fresh identify', (
      async,
      api,
    ) {
      _expireStored(async, api);
      expect(warnings(), hasLength(1));
      expect(warnings().single, contains('signature expired (401)'));
      final from = api.requests.length;
      Encatch.trackEvent('while-expired');
      async.elapse(const Duration(seconds: 2));
      expect(_eventsAfter(api, from), 0);
      _identify(async, api, 'alice');
      Encatch.trackEvent('after');
      async.elapse(const Duration(seconds: 2));
      expect(_eventsAfter(api, from), 1);
    }, callback: false);
  });

  group('held survey submits', () {
    final skipped = <String>[];
    setUp(skipped.clear);
    void onResponse(EncatchResponseInfo info) {
      if (info.outcome == 'skipped') {
        skipped.add('${info.endpoint} ${info.reason}');
      }
    }

    _testExpiry('a held submit is reported as skipped', (async, api) {
      _expireStored(async, api);
      Encatch.submitForm(_submit);
      async.flushMicrotasks();
      expect(skipped, contains('submit-form signature-expired'));
    }, onResponse: onResponse);

    _testExpiry('resetUser() drops them with a warning; never sent as the '
        'next user', (async, api) {
      _expireStored(async, api);
      Encatch.submitForm(_submit);
      Encatch.submitForm(_submit);
      async.flushMicrotasks();
      Encatch.resetUser();
      async.elapse(const Duration(seconds: 2));
      expect(warnings().last, contains('2 held survey submit(s) dropped'));
      _identify(async, api, 'bob');
      async.elapse(const Duration(seconds: 5));
      expect(api.count('submit-form'), 0);
    });

    _testExpiry('clearAll() drops them', (async, api) {
      _expireStored(async, api);
      Encatch.submitForm(_submit);
      async.flushMicrotasks();
      Encatch.clearAll();
      async.elapse(const Duration(seconds: 2));
      _identify(async, api, 'alice');
      async.elapse(const Duration(seconds: 5));
      expect(api.count('submit-form'), 0);
      expect(warnings().any((l) => l.contains('held survey submit')), isTrue);
    });

    _testExpiry('another user identified straight away: they are dropped, '
        'not sent as that user', (async, api) {
      _expireStored(async, api);
      Encatch.submitForm(_submit);
      async.flushMicrotasks();
      _identify(async, api, 'bob');
      expect(api.of('identify-user').last.status, 200);
      async.elapse(const Duration(seconds: 5));
      expect(api.count('submit-form'), 0);
      expect(warnings().last, contains('another user was identified'));
    });

    _testExpiry('at most 10 are kept, the oldest dropped', (async, api) {
      _expireStored(async, api);
      for (var i = 0; i < 12; i++) {
        Encatch.submitForm(
          SubmitFormRequest(
            triggerType: TriggerType.manual,
            formDetails: FormDetails(
              formConfigurationId: defaultFormId,
              isPartialSubmit: false,
              feedbackIdentifier: 'f$i',
            ),
          ),
        );
      }
      async.flushMicrotasks();
      _identify(async, api, 'alice');
      async.elapse(const Duration(seconds: 5));
      final sent = api.of('submit-form');
      expect(sent, hasLength(10));
      expect(
        sent.map((r) => (r.body['formDetails'] as Map)['feedbackIdentifier']),
        [for (var i = 2; i < 12; i++) 'f$i'],
      );
    });

    _testExpiry('a submit rejected with the reason (a gateway that checks '
        'every request) is held and sent after a fresh identify', (async, api) {
      _identify(async, api, 'alice');
      api.scenario.enforceSignatureOnAllRequests = true;
      // Before any ping finds it.
      async.elapse(const Duration(minutes: 16, seconds: 1));
      api.clearRequests();
      _calls.clear();
      Encatch.submitForm(_submit);
      async.elapse(const Duration(seconds: 2));
      expect(api.of('submit-form').first.status, 401);
      _identify(async, api, 'alice');
      async.elapse(const Duration(seconds: 5));
      expect(api.of('submit-form').last.status, 200);
    });
  });

  group('fake gateway (the contract the SDK is tested against)', () {
    final api = FakeApi();
    final key = api.scenario.apiKeys[_key]!;
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, String> headers(String name, String time) => {
      'x-user-name': name,
      'x-user-signature': hmacHex('$name$time', defaultSecret),
      'x-user-session-time': time,
    };

    test('a time in seconds is rejected', () {
      final seconds = '${now ~/ 1000}';
      expect(
        api.signatureResult(headers('alice', seconds), key),
        'invalid-timestamp',
      );
    });

    test('a minute ahead is fine; ten minutes ahead is rejected', () {
      expect(
        api.signatureResult(headers('alice', '${now + 60000}'), key),
        'ok',
      );
      expect(
        api.signatureResult(headers('alice', '${now + 600000}'), key),
        'invalid-timestamp',
      );
    });

    test('"alice0" + T does not pass as "alice" + "0T"', () {
      final signed = headers('alice0', '$now');
      final replay = {
        'x-user-name': 'alice',
        'x-user-signature': signed['x-user-signature']!,
        'x-user-session-time': '0$now',
      };
      expect(api.signatureResult(replay, key), 'invalid-timestamp');
    });

    test(
      'a key with a session time but no secret: the time is not checked',
      () {
        const noSecret = FakeApiKey(sessionTimeMinutes: 15);
        expect(
          api.signatureResult({
            'x-user-name': 'alice',
            'x-user-session-time': '1',
          }, noSecret),
          'ok',
        );
      },
    );
  });
}
