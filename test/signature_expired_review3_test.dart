// Cases from the third round of the Fable review of onSignatureExpired.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/http_error.dart';
import 'package:encatch_flutter/src/logger.dart';
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
  final lines = <String>[];
  setUp(() {
    lines.clear();
    EncatchLogger.sink = (output, _) => lines.add(output);
  });
  tearDown(() => EncatchLogger.sink = null);

  testFake('a signed-in user\'s submit answered 401 (no expiry) still '
      'fails for the caller', (async, api) {
    identify(async, 'alice');
    api.scenario.faults.add(Fault('submit-form', status: 401));
    Object? error;
    var done = false;
    Encatch.submitForm(_submit).then<void>(
      (_) {
        done = true;
      },
      onError: (Object e) {
        error = e;
      },
    );
    async.elapse(const Duration(seconds: 2));
    expect(done, isFalse);
    expect(error, isA<EncatchHttpException>());
    expect(httpStatusOf(error!), 401);
  });

  testFake('a signed-in user\'s submit in a 429 pause, then resetUser(): '
      'dropped, never sent as a visitor', (async, api) {
    identify(async, 'alice');
    api.scenario.faults.add(
      Fault('submit-form', status: 429, retryAfterSeconds: 30),
    );
    Encatch.submitForm(_submit);
    async.elapse(const Duration(seconds: 2));
    Encatch.resetUser();
    async.elapse(const Duration(seconds: 40));
    expect(api.of('submit-form').map((r) => r.status), [429]);
  });

  testFake('a visitor\'s submit in a 429 pause, then identify: sent', (
    async,
    api,
  ) {
    api.scenario.faults.add(
      Fault('submit-form', status: 429, retryAfterSeconds: 30),
    );
    Encatch.submitForm(_submit);
    async.elapse(const Duration(seconds: 2));
    Encatch.identifyUser('alice');
    async.elapse(const Duration(seconds: 40));
    expect(api.of('submit-form').map((r) => r.status), [429, 200]);
  });

  testFake('retries exhausted for the current user: still reset', (async, api) {
    identify(async, 'alice');
    api.scenario.userPending = true;
    api.scenario.userPendingExhaustAfter = 1;
    Encatch.trackEvent('x');
    async.elapse(const Duration(seconds: 2));
    expect(Encatch.userName, isNull);
  });

  testFake('retries exhausted for alice while identifyUser(bob) is held '
      'by a 429 pause: bob is identified when the pause ends', (async, api) {
    identify(async, 'alice');
    async.elapse(const Duration(seconds: 2));
    api.scenario.faults.addAll([
      Fault('ping', status: 429, retryAfterSeconds: 30),
      Fault('track-event', delay: const Duration(seconds: 5)),
    ]);
    api.scenario.userPending = true;
    api.scenario.userPendingExhaustAfter = 1;
    Encatch.trackEvent('x');
    async.elapse(const Duration(milliseconds: 500));
    expect(api.of('track-event').last.status, 0, reason: 'in flight');
    Encatch.startSession();
    async.elapse(const Duration(milliseconds: 500));
    expect(api.of('ping').last.status, 429, reason: 'pause started');
    Encatch.identifyUser('bob');
    async.elapse(const Duration(seconds: 10));
    expect(
      api.of('track-event').last.reply?['userPendingRetryExhausted'],
      isTrue,
    );
    api.scenario.userPending = false;
    expect(Encatch.userName, 'alice', reason: 'not reset; bob is held');
    async.elapse(const Duration(seconds: 40));
    expect(Encatch.userName, 'bob');
    expect(Encatch.isIdentified, isTrue);
    expect(api.of('identify-user').last.body['userName'], 'bob');
  });
}
