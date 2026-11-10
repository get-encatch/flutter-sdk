// Checks the fake API against the server contract it copies (the mock API's
// CONTRACT.md in the React Native repo). These tests call the fake directly,
// without the SDK, so a failure here means the fake is wrong, not the SDK.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'helpers/fake_api.dart';

const _base = 'https://fake-api.local/engage-product/encatch/api/v2/encatch';

Map<String, String> _headers({
  String? apiKey = defaultApiKey,
  String? referer = 'com.encatch.test',
  String? session = 's-1',
  String? device = 'd-1',
  String? userName,
  String? userId,
  Map<String, String> extra = const {},
}) => {
  'Content-Type': 'application/json',
  'X-Api-Key': ?apiKey,
  'Referer': ?referer,
  'X-Session-Id': ?session,
  'X-Device-Id': ?device,
  'X-User-Name': ?userName,
  'X-User-Id': ?userId,
  ...extra,
};

Future<http.Response> _post(
  FakeApi api,
  String endpoint, {
  Map<String, String>? headers,
  Map<String, dynamic> body = const {},
}) => api.client.post(
  Uri.parse('$_base/$endpoint'),
  headers: headers ?? _headers(),
  body: jsonEncode(body),
);

Map<String, dynamic> _json(http.Response r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

/// Runs [body] under fake time and waits for it to finish.
void _fake(Future<void> Function(FakeAsync async) body) {
  fakeAsync((async) {
    Object? error;
    StackTrace? stack;
    var done = false;
    body(async).then(
      (_) => done = true,
      onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
      },
    );
    async.flushMicrotasks();
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    expect(done, isTrue, reason: 'the test body is waiting on a timer');
  });
}

void main() {
  late FakeApi api;
  setUp(() => api = FakeApi());

  group('gateway', () {
    test('rejects a missing key, referer or unknown key', () async {
      var r = await _post(api, 'ping', headers: _headers(apiKey: null));
      expect(r.statusCode, 401);
      expect(_json(r)['error'], 'api key is required');

      r = await _post(api, 'ping', headers: _headers(referer: null));
      expect(r.statusCode, 401);
      expect(_json(r)['error'], 'referer is required');

      r = await _post(api, 'ping', headers: _headers(apiKey: 'nope'));
      expect(r.statusCode, 401);
      expect(_json(r)['error'], 'invalid api key');
    });

    test('unknown routes are 404', () async {
      final r = await api.client.post(Uri.parse('https://fake-api.local/x'));
      expect(r.statusCode, 404);
    });

    test('per-endpoint limit: 429 with Retry-After, and no quota used', () {
      _fake((async) async {
        api.scenario.rateLimit = RateLimit.perEndpoint5;
        for (var i = 0; i < 5; i++) {
          final ok = await _post(api, 'ping');
          expect(ok.statusCode, 200);
        }
        final limited = await _post(api, 'ping');
        expect(limited.statusCode, 429);
        expect(_json(limited)['error'], 'rate limit exceeded');
        expect(limited.headers['retry-after'], '60');
        // Another endpoint has its own bucket.
        expect((await _post(api, 'track-screen')).statusCode, 200);

        async.elapse(const Duration(seconds: 59));
        expect((await _post(api, 'ping')).headers['retry-after'], '1');
        async.elapse(const Duration(seconds: 1));
        expect((await _post(api, 'ping')).statusCode, 200);
      });
    });

    test('shared limit: every endpoint uses one bucket', () async {
      api.scenario.rateLimit = RateLimit.tiny;
      for (final e in ['ping', 'track-screen', 'ping', 'ping', 'ping']) {
        expect((await _post(api, e)).statusCode, 200);
      }
      expect((await _post(api, 'track-screen')).statusCode, 429);
    });
  });

  group('secure identify', () {
    Future<int> identify(String key, Map<String, String> extra) async {
      final r = await _post(
        api,
        'identify-user',
        headers: _headers(apiKey: key, userName: 'alice', extra: extra),
        body: {'userName': 'alice'},
      );
      return r.statusCode;
    }

    test('a key with a secret needs the X-User-Signature header', () async {
      expect(await identify(secureApiKey, {}), 401);
      expect(await identify(secureApiKey, {'X-User-Signature': 'wrong'}), 401);
      final sig = api.sign('alice', secureApiKey).signature;
      expect(await identify(secureApiKey, {'X-User-Signature': sig}), 200);
      // A key without a secret skips the check.
      expect(await identify(defaultApiKey, {}), 200);
    });

    test('a session-time key signs name + X-User-Session-Time', () {
      _fake((async) async {
        final signed = api.sign('alice', secureSessionApiKey);
        final sig = {'X-User-Signature': signed.signature};
        // No timestamp, or only the header the gateway doesn't read.
        expect(await identify(secureSessionApiKey, sig), 401);
        expect(
          await identify(secureSessionApiKey, {
            ...sig,
            'X-User-Signature-Time': signed.time!,
          }),
          401,
        );
        final good = {...sig, 'X-User-Session-Time': signed.time!};
        expect(await identify(secureSessionApiKey, good), 200);

        // Expires after the session time (15 minutes), in whole minutes.
        async.elapse(const Duration(minutes: 15, seconds: 59));
        expect(await identify(secureSessionApiKey, good), 200);
        async.elapse(const Duration(seconds: 1));
        expect(await identify(secureSessionApiKey, good), 401);
      });
    });

    test('the signature can be enforced on every request', () async {
      api.scenario.enforceSignatureOnAllRequests = true;
      final id = api.expectedUserId('alice');
      Future<int> ping(Map<String, String> extra) async => (await _post(
        api,
        'ping',
        headers: _headers(
          apiKey: secureApiKey,
          userName: 'alice',
          userId: id,
          extra: extra,
        ),
      )).statusCode;
      expect(await ping({}), 401);
      final sig = api.sign('alice', secureApiKey).signature;
      expect(await ping({'X-User-Signature': sig}), 200);
      // Visitors carry no name, so they are not checked.
      expect(
        (await _post(
          api,
          'ping',
          headers: _headers(apiKey: secureApiKey),
        )).statusCode,
        200,
      );
    });
  });

  group('identity', () {
    test('required headers', () async {
      final r = await _post(api, 'ping', headers: _headers(device: null));
      expect(r.statusCode, 400);
      expect(_json(r)['message'], 'Missing required header: X-Device-Id');
    });

    test('user ids are UUIDv5 of org:project:userName', () {
      expect(
        api.expectedUserId('alice'),
        '62cc2f35-96a6-5c6d-877b-e1e1a6078149',
      );
    });

    test('name and id must both be present or both absent', () async {
      final id = api.expectedUserId('alice');
      Future<http.Response> ping({String? name, String? userId}) => _post(
        api,
        'ping',
        headers: _headers(userName: name, userId: userId),
      );
      final nameOnly = await ping(name: 'alice');
      expect(nameOnly.statusCode, 401);
      expect(
        _json(nameOnly)['message'],
        'X-User-Name and X-User-Id must both be present or both absent',
      );
      expect((await ping(userId: id)).statusCode, 401);
      expect(
        (await ping(name: 'bob', userId: id)).statusCode,
        401,
        reason: "another user's id",
      );
      expect((await ping(name: 'alice', userId: 'x')).statusCode, 401);
      expect((await ping(name: 'alice', userId: id)).statusCode, 200);
      expect((await ping()).statusCode, 200, reason: 'visitor');
    });

    test('identify skips the identity rule and reads the body', () async {
      var r = await _post(
        api,
        'identify-user',
        headers: _headers(userName: 'someone-else', userId: 'stale'),
        body: {'userName': 'alice'},
      );
      expect(r.statusCode, 200);
      expect(_json(r)['userId'], api.expectedUserId('alice'));
      expect(_json(r)['pingAgainIn'], 10, reason: 'new user');

      r = await _post(api, 'identify-user', body: {'userName': 'alice'});
      expect(_json(r)['pingAgainIn'], 30, reason: 'known user');

      r = await _post(api, 'identify-user', body: {});
      expect(r.statusCode, 401);
    });

    test('user pending: exhausted on the fifth reply', () async {
      api.scenario.userPending = true;
      final headers = _headers(
        userName: 'alice',
        userId: api.expectedUserId('alice'),
      );
      for (var i = 0; i < 4; i++) {
        final r = _json(await _post(api, 'ping', headers: headers));
        expect(r['pingAgainIn'], 10);
        expect(r.containsKey('userPendingRetryExhausted'), isFalse);
      }
      final fifth = await _post(api, 'ping', headers: headers);
      expect(fifth.statusCode, 200);
      expect(_json(fifth)['pingAgainIn'], 900);
      expect(_json(fifth)['userPendingRetryExhausted'], isTrue);
      // Visitors are never pending.
      expect(_json(await _post(api, 'ping'))['pingAgainIn'], 30);
    });
  });

  group('events', () {
    test(
      'visitors: survey events 403, custom events need the setting',
      () async {
        for (final name in systemEvents) {
          final r = await _post(api, 'track-event', body: {'eventName': name});
          expect(r.statusCode, 403, reason: name);
          expect(
            _json(r)['message'],
            'Event tracking not allowed for visitors',
          );
        }
        expect(
          (await _post(
            api,
            'track-event',
            body: {'eventName': 'tap'},
          )).statusCode,
          403,
        );
        api.scenario.allowTrackEventForVisitors = true;
        expect(
          (await _post(
            api,
            'track-event',
            body: {'eventName': 'tap'},
          )).statusCode,
          200,
        );
        expect(
          (await _post(
            api,
            'track-event',
            body: {'eventName': 'form:show'},
          )).statusCode,
          403,
          reason: 'survey events stay forbidden for visitors',
        );
      },
    );

    test('identified users: survey and custom events accepted', () async {
      final headers = _headers(
        userName: 'alice',
        userId: api.expectedUserId('alice'),
      );
      for (final name in [...systemEvents, 'tap']) {
        final r = await _post(
          api,
          'track-event',
          headers: headers,
          body: {'eventName': name},
        );
        expect(r.statusCode, 200, reason: name);
      }
      expect(
        (await _post(api, 'track-event', headers: headers)).statusCode,
        400,
        reason: 'eventName is required',
      );
    });
  });

  group('surveys', () {
    test('every reply type can carry nextFeedbackId + onPageDelay', () async {
      const trigger = SurveyTrigger(defaultFormId, onPageDelay: 5);
      api.scenario
        ..identifyTrigger = trigger
        ..pingTrigger = trigger
        ..eventTriggers = {'buy': trigger}
        ..screenTriggers = {'/checkout': trigger}
        ..allowTrackEventForVisitors = true;
      final replies = [
        await _post(api, 'identify-user', body: {'userName': 'alice'}),
        await _post(api, 'ping'),
        await _post(api, 'track-event', body: {'eventName': 'buy'}),
        await _post(
          api,
          'track-screen',
          body: {
            r'$deviceInfo': {r'$urlOrScreenName': '/checkout'},
          },
        ),
      ];
      for (final r in replies) {
        final body = _json(r);
        expect(body['nextFeedbackId'], defaultFormId);
        expect(body['onPageDelay'], 5);
        expect(body.containsKey('formConfigurationId'), isFalse);
      }
      // pingAgainIn = 30 + delay, except a new user's identify (10).
      expect(_json(replies[1])['pingAgainIn'], 35);
      // Other screens and events carry no survey.
      final other = _json(
        await _post(
          api,
          'track-screen',
          body: {
            r'$deviceInfo': {r'$urlOrScreenName': '/home'},
          },
        ),
      );
      expect(other.containsKey('nextFeedbackId'), isFalse);
      expect(other['pingAgainIn'], 30);
    });

    test(
      'show-form: a repeated automatic show is 404, manual is not',
      () async {
        Future<http.Response> show(
          String type, [
          String form = defaultFormId,
        ]) => _post(
          api,
          'show-form',
          body: {'formSlugOrId': form, 'triggerType': type},
        );
        final first = await show('automatic');
        expect(first.statusCode, 200);
        expect(_json(first)['feedbackConfigurationId'], defaultFormId);

        final second = await show('automatic');
        expect(second.statusCode, 404);
        expect(
          _json(second)['message'],
          'Form not available: User is not eligible for this form',
        );
        expect((await show('manual')).statusCode, 200);
        expect((await show('manual')).statusCode, 200);
        expect((await show('automatic', secondFormId)).statusCode, 200);
        expect((await show('manual', 'no-such-form')).statusCode, 404);
        expect((await show('manual', 'mock-survey')).statusCode, 200);
        expect((await _post(api, 'show-form')).statusCode, 400);
      },
    );

    test('submit-form and dismiss-form', () async {
      expect((await _post(api, 'submit-form')).statusCode, 400);
      expect(
        (await _post(
          api,
          'submit-form',
          body: {
            'formDetails': {'formConfigurationId': defaultFormId},
          },
        )).statusCode,
        200,
      );

      // dismiss-form: a no-op for visitors, a UUID needed for known users.
      expect((await _post(api, 'dismiss-form')).statusCode, 200);
      final headers = _headers(
        userName: 'alice',
        userId: api.expectedUserId('alice'),
      );
      expect(
        (await _post(
          api,
          'dismiss-form',
          headers: headers,
          body: {'formConfigurationId': ''},
        )).statusCode,
        400,
      );
      expect(
        (await _post(
          api,
          'dismiss-form',
          headers: headers,
          body: {'formConfigurationId': defaultFormId},
        )).statusCode,
        200,
      );
    });
  });

  group('faults', () {
    test('a forced status applies to the next N calls only', () async {
      api.scenario.faults = [
        Fault('ping', count: 2, status: 429, retryAfterSeconds: 7),
      ];
      final first = await _post(api, 'ping');
      expect(first.statusCode, 429);
      expect(first.headers['retry-after'], '7');
      expect((await _post(api, 'track-screen')).statusCode, 200);
      expect((await _post(api, 'ping')).statusCode, 429);
      expect((await _post(api, 'ping')).statusCode, 200);
    });

    test('Retry-After can be an HTTP date', () async {
      api.scenario.faults = [
        Fault('ping', status: 429, retryAfter: 'Wed, 21 Oct 2026 07:28:00 GMT'),
      ];
      expect(
        (await _post(api, 'ping')).headers['retry-after'],
        'Wed, 21 Oct 2026 07:28:00 GMT',
      );
    });

    test('a dropped connection throws', () async {
      api.scenario.faults = [Fault('ping', drop: true)];
      await expectLater(
        _post(api, 'ping'),
        throwsA(isA<http.ClientException>()),
      );
      expect(api.of('ping').single.status, -1);
    });
  });

  test('every request is recorded with headers, body and status', () async {
    await _post(
      api,
      'track-event',
      headers: _headers(userName: 'alice', userId: api.expectedUserId('alice')),
      body: {'eventName': 'tap'},
    );
    final r = api.requests.single;
    expect(r.endpoint, 'track-event');
    expect(r.userName, 'alice');
    expect(r.eventName, 'tap');
    expect(r.status, 200);
    expect(api.count('track-event', status: 200), 1);
  });
}
