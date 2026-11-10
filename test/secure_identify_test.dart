// Step 9 (secure identify): the signature goes in the headers the gateway
// reads, then on every request for that user. These failed on 1.1.2.
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

/// Identifies [userName] with a signature from the "customer's backend".
void secureIdentify(FakeAsync async, FakeApi api, String userName, String key) {
  final signed = api.sign(userName, key);
  Encatch.identifyUser(
    userName,
    options: IdentifyOptions(
      secure: SecureOptions(
        signature: signed.signature,
        generatedDateTimeinUTC: signed.time,
      ),
    ),
  );
  async.flushMicrotasks();
}

void main() {
  group('9a: the gateway accepts a signed identify', () {
    testFake('key with a secret', (async, api) {
      secureIdentify(async, api, 'alice', secureApiKey);
      final request = api.of('identify-user').single;
      expect(request.status, 200);
      expect(
        request.headers['x-user-signature'],
        api.sign('alice', secureApiKey).signature,
      );
      expect(request.body['userSignature'], isNotNull, reason: 'kept in body');
      expect(Encatch.userId, api.expectedUserId('alice'));
    }, apiKey: secureApiKey);

    testFake('key with a session time', (async, api) {
      secureIdentify(async, api, 'alice', secureSessionApiKey);
      final request = api.of('identify-user').single;
      expect(request.status, 200);
      final time = request.headers['x-user-session-time'];
      expect(time, isNotNull);
      expect(request.headers['x-user-signature-time'], time);
      expect(Encatch.userId, api.expectedUserId('alice'));
    }, apiKey: secureSessionApiKey);

    testFake('a wrong signature is rejected and leaves a visitor', (
      async,
      api,
    ) {
      Encatch.identifyUser(
        'alice',
        options: const IdentifyOptions(
          secure: SecureOptions(signature: 'not-the-signature'),
        ),
      );
      async.flushMicrotasks();
      expect(api.of('identify-user').single.status, 401);

      Encatch.startSession();
      async.elapse(const Duration(seconds: 2));
      final ping = api.of('ping').first;
      expect(ping.userName, isNull);
      expect(ping.userId, isNull);
      expect(ping.headers.containsKey('x-user-signature'), isFalse);
    }, apiKey: secureApiKey);
  });

  group('9b: the signature goes on every request for that user', () {
    testFake(
      'sent after a secure identify, never for visitors, cleared by reset',
      (async, api) {
        // A visitor request before identifying carries no signature.
        Encatch.startSession();
        async.flushMicrotasks();
        expect(api.of('ping').single.status, 200);
        expect(
          api.of('ping').single.headers.containsKey('x-user-signature'),
          isFalse,
        );

        secureIdentify(async, api, 'alice', secureApiKey);
        api.clearRequests();
        Encatch.trackEvent('signed');
        Encatch.trackScreen('/signed');
        async.elapse(const Duration(seconds: 12));
        expect(api.requests, isNotEmpty);
        final signature = api.sign('alice', secureApiKey).signature;
        for (final r in api.requests) {
          expect(r.status, 200, reason: '$r');
          expect(r.headers['x-user-signature'], signature, reason: '$r');
        }

        Encatch.resetUser();
        async.flushMicrotasks();
        api.clearRequests();
        Encatch.startSession();
        async.flushMicrotasks();
        expect(
          api.of('ping').single.headers.containsKey('x-user-signature'),
          isFalse,
        );
      },
      apiKey: secureApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );

    testFake(
      "a user switch never sends the previous user's signature",
      (async, api) {
        secureIdentify(async, api, 'alice', secureApiKey);
        final aliceSignature = api.sign('alice', secureApiKey).signature;
        api.clearRequests();

        secureIdentify(async, api, 'bob', secureApiKey);
        Encatch.trackEvent('as-bob');
        async.elapse(const Duration(seconds: 2));
        final bobSignature = api.sign('bob', secureApiKey).signature;
        expect(api.requests, isNotEmpty);
        for (final r in api.requests) {
          expect(r.status, 200, reason: '$r');
          expect(r.headers['x-user-signature'], bobSignature, reason: '$r');
          expect(r.headers['x-user-signature'], isNot(aliceSignature));
        }
      },
      apiKey: secureApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );

    testFake(
      'an identify without secure clears the stored signature',
      (async, api) {
        secureIdentify(async, api, 'alice', secureApiKey);
        Encatch.trackEvent('signed');
        async.elapse(const Duration(seconds: 2));
        expect(
          api.of('track-event').single.headers['x-user-signature'],
          api.sign('alice', secureApiKey).signature,
        );
        // The gateway rejects this unsigned identify; either way the old
        // signature must not be sent again.
        Encatch.identifyUser('alice', traits: const UserTraits(set: {'a': 1}));
        async.elapse(const Duration(seconds: 2));
        api.clearRequests();
        Encatch.trackEvent('after');
        async.elapse(const Duration(seconds: 2));
        for (final r in api.requests) {
          expect(r.headers.containsKey('x-user-signature'), isFalse);
        }
      },
      apiKey: secureApiKey,
      configure: (api) => api.scenario.allowTrackEventForVisitors = true,
    );

    testFake(
      'the signature survives an app restart',
      (async, api) {
        secureIdentify(async, api, 'alice', secureApiKey);
        startSdk(api, apiKey: secureApiKey, keepStorage: true);
        async.flushMicrotasks();
        expect(Encatch.userName, 'alice');

        api.clearRequests();
        Encatch.trackEvent('after-restart');
        async.elapse(const Duration(seconds: 2));
        final event = api.of('track-event').single;
        expect(event.status, 200);
        expect(
          event.headers['x-user-signature'],
          api.sign('alice', secureApiKey).signature,
        );
      },
      apiKey: secureApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );

    testFake(
      'an expired signature stops background traffic and holds a submit',
      (async, api) {
        secureIdentify(async, api, 'alice', secureSessionApiKey);
        expect(api.of('identify-user').single.status, 200);

        // The session time is 15 minutes. Pings carry the signature; once it
        // expires the gateway answers 401.
        async.elapse(const Duration(minutes: 17));
        final rejected = api.requests.where((r) => r.status == 401);
        expect(rejected, hasLength(1), reason: 'one 401, then the SDK stops');

        api.clearRequests();
        Encatch.trackEvent('while-expired');
        Encatch.trackScreen('/while-expired');
        async.elapse(const Duration(minutes: 5));
        expect(api.requests, isEmpty, reason: 'no 401 storm');

        // A survey submit is held, then sent after the next identify.
        var submitted = false;
        Encatch.submitForm(_submit).then((_) => submitted = true);
        async.elapse(const Duration(seconds: 5));
        expect(api.count('submit-form'), 0);

        secureIdentify(async, api, 'alice', secureSessionApiKey);
        async.elapse(const Duration(seconds: 5));
        expect(api.of('identify-user').last.status, 200);
        expect(api.of('submit-form').single.status, 200);
        expect(submitted, isTrue);
      },
      apiKey: secureSessionApiKey,
      configure: (api) => api.scenario.enforceSignatureOnAllRequests = true,
    );
  });
}
