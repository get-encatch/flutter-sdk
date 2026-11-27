// Cases from the second round of the Fable review of onSignatureExpired.
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
final _calls = <String>[];
FutureOr<void> Function(String userName)? _then;

FutureOr<void> _hook(SignatureExpiredInfo info) {
  _calls.add(info.userName);
  return _then?.call(info.userName);
}

IdentifyOptions _signed(
  FakeApi api,
  String user, {
  Duration age = Duration.zero,
}) {
  final signed = api.sign(user, _key, age: age);
  return IdentifyOptions(
    secure: SecureOptions(
      signature: signed.signature,
      generatedDateTimeinUTC: signed.time,
    ),
  );
}

void _identify(
  FakeAsync async,
  FakeApi api,
  String user, {
  Duration age = Duration.zero,
}) {
  Encatch.identifyUser(user, options: _signed(api, user, age: age));
  async.elapse(const Duration(seconds: 2));
}

const _stale = Duration(minutes: 20);

void _t(
  String d,
  void Function(FakeAsync async, FakeApi api) body, {
  void Function(FakeApi api)? configure,
  String apiKey = _key,
}) => testFake(
  d,
  body,
  apiKey: apiKey,
  configure: configure,
  onSignatureExpired: _hook,
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

  _t('a visitor\'s submit that got 429 is still sent when the visitor '
      'signs in during the pause', (async, api) {
    api.scenario.faults.add(
      Fault('submit-form', status: 429, retryAfterSeconds: 30),
    );
    Encatch.submitForm(_submit);
    async.elapse(const Duration(seconds: 2));
    expect(api.of('submit-form').single.status, 429);
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 40));
    expect(
      api.of('submit-form').where((r) => r.status == 200),
      hasLength(1),
      reason: lines.where((l) => l.contains('dropped')).join('\n'),
    );
  }, apiKey: defaultApiKey);

  _t('a visitor submits and the app identifies in the same tick: the '
      'answers are sent', (async, api) {
    Encatch.submitForm(_submit);
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 5));
    expect(
      api.of('submit-form').where((r) => r.status == 200),
      hasLength(1),
      reason: lines.where((l) => l.contains('dropped')).join('\n'),
    );
  }, apiKey: defaultApiKey);

  _t('older gateway: identifyUser re-sending the stored signature, 401 '
      'without the reason: not the expired state, not called', (async, api) {
    final options = _signed(api, 'alice');
    Encatch.identifyUser('alice', options: options);
    async.elapse(const Duration(seconds: 2));
    async.elapse(const Duration(minutes: 17));
    Encatch.identifyUser('alice', traits: _pro, options: options);
    async.elapse(const Duration(seconds: 2));
    expect(api.of('identify-user').map((r) => r.status), [200, 401]);
    expect(_calls, isEmpty);
    final from = api.requests.length;
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 2));
    expect(
      api.requests.skip(from).where((r) => r.endpoint == 'track-event'),
      hasLength(1),
    );
  }, configure: (api) => api.scenario.expiredSignatureReason = false);

  _t('a rejected new signature and the stored one found expired in the '
      'same instant: called once', (async, api) {
    _identify(async, api, 'alice');
    Encatch.stopSession();
    async.elapse(const Duration(minutes: 16));
    api.scenario.enforceSignatureOnAllRequests = true;
    api.scenario.faults.addAll([
      Fault('identify-user', delay: const Duration(seconds: 5)),
      Fault('submit-form', delay: const Duration(seconds: 5)),
    ]);
    Encatch.identifyUser('alice', options: _signed(api, 'alice', age: _stale));
    Encatch.submitForm(_submit);
    async.elapse(const Duration(seconds: 10));
    expect(
      api.requests.where((r) => r.status == 401).map((r) => r.endpoint),
      unorderedEquals(['identify-user', 'submit-form']),
    );
    expect(_calls, ['alice']);
  });

  _t('the callback re-sends the same expired stored signature: no loop', (
    async,
    api,
  ) {
    final options = _signed(api, 'alice');
    _then = (user) {
      if (_calls.length < 5) {
        Encatch.identifyUser(
          user,
          traits: UserTraits(set: {'n': _calls.length}),
          options: options,
        );
      }
    };
    Encatch.identifyUser('alice', options: options);
    async.elapse(const Duration(seconds: 2));
    async.elapse(const Duration(minutes: 17));
    Encatch.identifyUser('alice', traits: _pro, options: options);
    async.elapse(const Duration(minutes: 1));
    expect(_calls, ['alice']);
  });

  _t('429 pause: identifyUser(bob) is held; alice\'s late expiry reply is '
      'ignored; bob is identified when the pause ends', (async, api) {
    _identify(async, api, 'alice');
    async.elapse(const Duration(minutes: 17));
    api.scenario.faults.add(
      Fault('identify-user', delay: const Duration(seconds: 5)),
    );
    Encatch.setUserProperties('alice', _pro);
    async.elapse(const Duration(seconds: 1));
    api.scenario.faults.add(Fault('ping', status: 429, retryAfterSeconds: 30));
    Encatch.startSession();
    async.elapse(const Duration(seconds: 1));
    expect(api.of('ping').last.status, 429, reason: 'pause started');
    Encatch.identifyUser('bob', options: _signed(api, 'bob'));
    async.elapse(const Duration(seconds: 10));
    expect(api.of('identify-user').last.status, 401);
    expect(Encatch.userName, 'alice', reason: 'bob is held');
    expect(_calls, isEmpty);
    async.elapse(const Duration(seconds: 40));
    expect(Encatch.userName, 'bob');
    expect(api.of('identify-user').last.status, 200);
    expect(_calls, isEmpty);
    final from = api.requests.length;
    Encatch.trackEvent('y');
    async.elapse(const Duration(seconds: 2));
    expect(
      api.requests.skip(from).where((r) => r.endpoint == 'track-event'),
      hasLength(1),
    );
  });

  _t('429 pause: identifyUser(bob) held, then alice again (a repeat): '
      'alice\'s expiry is still detected', (async, api) {
    _identify(async, api, 'alice');
    async.elapse(const Duration(minutes: 17));
    api.scenario.faults.add(
      Fault('track-event', status: 429, retryAfterSeconds: 30),
    );
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 1));
    final same = api.of('identify-user').first.headers;
    Encatch.identifyUser('bob', options: _signed(api, 'bob'));
    async.flushMicrotasks();
    Encatch.identifyUser(
      'alice',
      options: IdentifyOptions(
        secure: SecureOptions(
          signature: same['x-user-signature']!,
          generatedDateTimeinUTC: same['x-user-session-time'],
        ),
      ),
    );
    async.elapse(const Duration(seconds: 40));
    expect(Encatch.userName, 'alice');
    Encatch.setUserProperties('alice', _pro);
    async.elapse(const Duration(seconds: 2));
    expect(api.of('identify-user').last.status, 401);
    expect(_calls, ['alice']);
  });
}
