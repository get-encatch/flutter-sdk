// Cases found in the Fable review of onSignatureExpired. Each failed before
// the fix that follows it.
import 'dart:async';

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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

void _expireStored(FakeAsync async, FakeApi api) {
  _identify(async, api, 'alice');
  expect(api.of('identify-user').last.status, 200);
  async.elapse(const Duration(minutes: 17));
  Encatch.setUserProperties('alice', _pro);
  async.elapse(const Duration(seconds: 2));
  expect(api.of('identify-user').last.status, 401);
}

/// Storage whose writes take time, as on a device (a platform channel call).
class SlowStore extends SharedPreferencesStorePlatform {
  SlowStore(this.inner, this.delay);
  final SharedPreferencesStorePlatform inner;
  final Duration delay;
  @override
  bool get isMock => true;
  @override
  Future<bool> clear() async {
    await Future<void>.delayed(delay);
    return inner.clear();
  }

  @override
  Future<Map<String, Object>> getAll() => inner.getAll();
  @override
  Future<bool> remove(String key) async {
    await Future<void>.delayed(delay);
    return inner.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await Future<void>.delayed(delay);
    return inner.setValue(valueType, key, value);
  }
}

void _slowStorage() {
  SharedPreferencesStorePlatform.instance = SlowStore(
    SharedPreferencesStorePlatform.instance,
    const Duration(milliseconds: 7),
  );
}

void _t(
  String d,
  void Function(FakeAsync async, FakeApi api) body, {
  void Function(FakeApi api)? configure,
  String apiKey = _key,
  void Function(EncatchResponseInfo info)? onResponse,
}) => testFake(
  d,
  body,
  apiKey: apiKey,
  configure: configure,
  onResponse: onResponse,
  onSignatureExpired: _hook,
);

void main() {
  final lines = <String>[];
  final skipped = <String>[];
  setUp(() {
    _calls.clear();
    _then = null;
    lines.clear();
    skipped.clear();
    EncatchLogger.sink = (output, _) => lines.add(output);
  });
  tearDown(() => EncatchLogger.sink = null);
  void onResponse(EncatchResponseInfo info) {
    if (info.outcome == 'skipped') {
      skipped.add('${info.endpoint} ${info.reason}');
    }
  }

  // --- RN parity -----------------------------------------------------------

  _t('told about a stale new signature, then the stored one expires: '
      'told again', (async, api) {
    _identify(async, api, 'alice');
    _identify(async, api, 'alice', age: _stale);
    expect(_calls, ['alice']);
    async.elapse(const Duration(minutes: 17));
    Encatch.setUserProperties('alice', _pro);
    async.elapse(const Duration(seconds: 2));
    expect(api.of('identify-user').map((r) => r.status), [200, 401, 401]);
    final from = api.requests.length;
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 2));
    expect(
      api.requests.skip(from).where((r) => r.endpoint == 'track-event'),
      isEmpty,
      reason: 'expired state entered',
    );
    expect(_calls, ['alice', 'alice'], reason: 'state entered silently');
  });

  _t('an identify that re-sent the stored signature, rejected as expired, '
      'enters the expired state', (async, api) {
    final options = _signed(api, 'alice');
    Encatch.identifyUser('alice', options: options);
    async.elapse(const Duration(seconds: 2));
    async.elapse(const Duration(minutes: 17));
    Encatch.identifyUser('alice', traits: _pro, options: options);
    async.elapse(const Duration(seconds: 2));
    expect(api.of('identify-user').map((r) => r.status), [200, 401]);
    expect(_calls, ['alice']);
    final from = api.requests.length;
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 2));
    final events = api.requests
        .skip(from)
        .where((r) => r.endpoint == 'track-event')
        .toList();
    expect(
      events.map((r) => r.headers['x-user-signature']),
      isEmpty,
      reason: 'event still sent with the signature known to be expired',
    );
  });

  _t('a key without a session time: 401 without reason on '
      'setUserProperties is not an expiry', (async, api) {
    final signed = api.sign('alice', secureApiKey);
    Encatch.identifyUser(
      'alice',
      options: IdentifyOptions(
        secure: SecureOptions(signature: signed.signature),
      ),
    );
    async.elapse(const Duration(seconds: 2));
    expect(api.of('identify-user').last.status, 200);
    api.scenario.faults.add(Fault('identify-user', status: 401));
    Encatch.setUserProperties('alice', _pro);
    async.elapse(const Duration(seconds: 2));
    expect(api.of('identify-user').last.status, 401);
    expect(_calls, isEmpty);
    final from = api.requests.length;
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 2));
    expect(
      api.requests.skip(from).where((r) => r.endpoint == 'track-event'),
      hasLength(1),
    );
  }, apiKey: secureApiKey);

  // --- resetUser()/clearAll() already called, reply lands while they save ---

  void inFlightExpiry(FakeAsync async, FakeApi api) {
    _identify(async, api, 'alice');
    async.elapse(const Duration(minutes: 17));
    api.scenario.faults.add(
      Fault('identify-user', delay: const Duration(seconds: 5)),
    );
    Encatch.setUserProperties('alice', _pro);
    async.elapse(const Duration(milliseconds: 4997));
    expect(api.of('identify-user').last.status, 0, reason: 'in flight');
    _slowStorage();
  }

  _t('resetUser() called 3 ms before the expiry reply: not called', (
    async,
    api,
  ) {
    inFlightExpiry(async, api);
    Encatch.resetUser();
    async.elapse(const Duration(seconds: 5));
    expect(api.of('identify-user').last.status, 401);
    expect(Encatch.userName, isNull);
    expect(_calls, isEmpty);
  });

  _t('then a callback that identifies again does not sign the user who '
      'was just reset back in', (async, api) {
    _then = (user) {
      Encatch.identifyUser(user, options: _signed(api, user));
    };
    inFlightExpiry(async, api);
    Encatch.resetUser();
    async.elapse(const Duration(seconds: 5));
    expect(Encatch.userName, isNull);
  });

  _t('clearAll() called 3 ms before the expiry reply: not called', (
    async,
    api,
  ) {
    inFlightExpiry(async, api);
    Encatch.clearAll();
    async.elapse(const Duration(seconds: 5));
    expect(api.of('identify-user').last.status, 401);
    expect(Encatch.userName, isNull);
    expect(_calls, isEmpty);
  });

  _t('switch to bob called 3 ms before alice\'s stale-identify reply: '
      'not called for alice', (async, api) {
    _identify(async, api, 'alice');
    api.scenario.faults.add(
      Fault('identify-user', delay: const Duration(seconds: 5)),
    );
    Encatch.identifyUser('alice', options: _signed(api, 'alice', age: _stale));
    async.elapse(const Duration(milliseconds: 4997));
    _slowStorage();
    Encatch.identifyUser('bob', options: _signed(api, 'bob'));
    async.elapse(const Duration(seconds: 5));
    expect(Encatch.userName, 'bob');
    expect(_calls, isEmpty);
  });

  // --- wrong user -----------------------------------------------------------

  _t('a held submit, resent, gets 429; the user switches during the '
      'pause: never sent as the other user', (async, api) {
    _expireStored(async, api);
    Encatch.submitForm(_submit);
    async.flushMicrotasks();
    api.scenario.faults.add(
      Fault('submit-form', status: 429, retryAfterSeconds: 30),
    );
    _identify(async, api, 'alice');
    expect(api.of('submit-form').single.status, 429);
    _identify(async, api, 'bob');
    expect(Encatch.userName, 'bob');
    async.elapse(const Duration(seconds: 40));
    final sent = api.of('submit-form').where((r) => r.status == 200);
    expect(sent.map((r) => r.userName), isNot(contains('bob')));
  });

  _t('(no expiry involved) a plain submit that got 429 is not retried as '
      'the user who is current after the pause', (async, api) {
    _identify(async, api, 'alice');
    api.scenario.faults.add(
      Fault('submit-form', status: 429, retryAfterSeconds: 30),
    );
    Encatch.submitForm(_submit);
    async.elapse(const Duration(seconds: 2));
    _identify(async, api, 'bob');
    async.elapse(const Duration(seconds: 40));
    final sent = api.of('submit-form').where((r) => r.status == 200);
    expect(sent.map((r) => r.userName), isNot(contains('bob')));
  });

  // --- state left stuck ------------------------------------------------------

  _t('alice expired, then a switch to bob whose identify fails: bob\'s '
      'traffic is not paused for alice\'s signature', (async, api) {
    _expireStored(async, api);
    api.scenario.faults.add(Fault('identify-user', status: 401));
    _identify(async, api, 'bob');
    expect(api.of('identify-user').last.status, 401);
    final from = api.requests.length;
    skipped.clear();
    Encatch.trackScreen('/home');
    async.elapse(const Duration(seconds: 2));
    expect(skipped, isEmpty);
    expect(
      api.requests.skip(from).where((r) => r.endpoint == 'track-screen'),
      hasLength(1),
    );
  }, onResponse: onResponse);

  _t('stop() between the reply and the callback, then a later stale '
      'identify: the app is told at some point', (async, api) {
    _identify(async, api, 'alice');
    async.elapse(const Duration(minutes: 17));
    Encatch.setUserProperties('alice', _pro);
    for (var i = 0; i < 50 && api.count('identify-user') < 2; i++) {
      async.flushMicrotasks();
    }
    async.flushMicrotasks();
    expect(api.of('identify-user').last.status, 401);
    Encatch.stop();
    async.elapse(const Duration(seconds: 5));
    expect(_calls, isEmpty, reason: 'stop() cancels it');
    // The SDK is still initialised; the app carries on.
    _identify(async, api, 'alice', age: _stale);
    expect(api.of('identify-user').last.status, 401);
    expect(_calls, ['alice']);
  });
}
