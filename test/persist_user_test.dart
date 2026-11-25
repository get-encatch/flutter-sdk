// EncatchConfig.persistUserAcrossRestarts. With false the user lives in memory
// for the current app run only: nothing about them is saved on the device.
// The default (true) saves the user and restores them at the next launch.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/harness.dart';

/// Keys on the device that hold something about a user: the name, user ids,
/// secure signatures and survey history.
Future<List<String>> savedUserKeys() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs
      .getKeys()
      .where(
        (k) =>
            k == 'encatch_user_name' ||
            k.startsWith('encatch_user_id_') ||
            k.startsWith('encatch_user_signature_') ||
            k.startsWith('encatch_ft_'),
      )
      .toList()
    ..sort();
}

/// A secure identify, with a signature from the "customer's backend".
Future<void> secureIdentify(FakeApi api, String userName) {
  final signed = api.sign(userName, secureApiKey);
  return Encatch.identifyUser(
    userName,
    options: IdentifyOptions(
      secure: SecureOptions(
        signature: signed.signature,
        generatedDateTimeinUTC: signed.time,
      ),
    ),
  );
}

/// Lets the queue send what it holds and the replies be applied.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  tearDown(stopSdk);

  group('persistUserAcrossRestarts: false', () {
    test('nothing about the user is saved, and requests still go out as the '
        'user', () async {
      final api = FakeApi();
      await startSdk(
        api,
        apiKey: secureApiKey,
        persistUserAcrossRestarts: false,
      );
      await secureIdentify(api, 'alice');
      await settle();
      await Encatch.trackEvent('purchase');
      await settle();

      expect(api.count('identify-user', status: 200), 1);
      expect(Encatch.isIdentified, isTrue);
      final event = requestsAs(api, 'alice', 'track-event').single;
      expect(event.status, 200);
      expect(
        event.headers['x-user-signature'],
        api.sign('alice', secureApiKey).signature,
      );
      expect(await savedUserKeys(), isEmpty);
    });

    test('after a restart the user is a visitor', () async {
      final api = FakeApi();
      await startSdk(api, persistUserAcrossRestarts: false);
      await Encatch.identifyUser('alice');
      await settle();
      expect(Encatch.isIdentified, isTrue);

      // Restart: memory is gone, what is on the device is kept.
      await startSdk(api, keepStorage: true, persistUserAcrossRestarts: false);
      api.clearRequests();
      expect(Encatch.isIdentified, isFalse);
      expect(Encatch.userName, isNull);
      expect(Encatch.userId, isNull);

      await Encatch.startSession();
      await Encatch.trackScreen('/home');
      await settle();
      expect(api.count('ping'), 1);
      expect(api.count('track-screen'), 1);
      expect(api.requests.where((r) => r.userName != null), isEmpty);
      expect(api.requests.where((r) => r.userId != null), isEmpty);
    });

    test('user data an earlier run saved is deleted at init', () async {
      final api = FakeApi();
      // An earlier run, with the default.
      await startSdk(api, apiKey: secureApiKey);
      await secureIdentify(api, 'alice');
      await settle();
      await Encatch.identifyUser('bob');
      await settle();
      expect(await savedUserKeys(), isNotEmpty);
      expect(
        await savedUserKeys(),
        containsAll(['encatch_user_name', 'encatch_user_id_alice']),
      );

      await startSdk(
        api,
        apiKey: secureApiKey,
        keepStorage: true,
        persistUserAcrossRestarts: false,
      );
      expect(await savedUserKeys(), isEmpty);
      expect(Encatch.isIdentified, isFalse);
      expect(Encatch.userName, isNull);
    });

    test(
      'the device id, a saved stop and preferences are still saved',
      () async {
        final api = FakeApi();
        await startSdk(api, persistUserAcrossRestarts: false);
        final deviceId = Encatch.deviceId;
        await Encatch.identifyUser(
          'alice',
          options: const IdentifyOptions(locale: 'fr', country: 'FR'),
        );
        await settle();
        await Encatch.stopSession();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('encatch_device_id'), deviceId);
        expect(prefs.getBool('encatch_session_stopped'), isTrue);
        expect(prefs.getString('encatch_preferences'), contains('fr'));

        await startSdk(
          api,
          keepStorage: true,
          persistUserAcrossRestarts: false,
        );
        expect(Encatch.deviceId, deviceId);
        expect(Encatch.locale, 'fr');
      },
    );

    test('switching back to an earlier user reuses their id at once', () async {
      final api = FakeApi();
      await startSdk(api, persistUserAcrossRestarts: false);
      await Encatch.identifyUser('alice');
      await settle();
      await Encatch.identifyUser('bob');
      await settle();
      expect(Encatch.userId, api.expectedUserId('bob'));

      // Back to alice: her id is known before the reply arrives.
      api.scenario.latency = const Duration(milliseconds: 200);
      await Encatch.identifyUser('alice');
      expect(Encatch.userName, 'alice');
      expect(Encatch.userId, api.expectedUserId('alice'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await savedUserKeys(), isEmpty);
    });

    test('clearAll() also forgets the user kept in memory', () async {
      final api = FakeApi();
      await startSdk(api, persistUserAcrossRestarts: false);
      await Encatch.identifyUser('alice');
      await settle();
      await Encatch.identifyUser('bob');
      await settle();
      await Encatch.clearAll();
      expect(Encatch.isIdentified, isFalse);
      expect(Encatch.userName, isNull);

      // Nothing is left of either user: alice's id has to come from the server
      // again.
      api.scenario.latency = const Duration(milliseconds: 200);
      await Encatch.identifyUser('alice');
      expect(Encatch.userId, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(Encatch.userId, api.expectedUserId('alice'));
    });
  });

  group('persistUserAcrossRestarts: the default (true) is unchanged', () {
    test('the user is restored after a restart', () async {
      final api = FakeApi();
      await startSdk(api, apiKey: secureApiKey);
      await secureIdentify(api, 'alice');
      await settle();
      expect(
        await savedUserKeys(),
        containsAll([
          'encatch_user_name',
          'encatch_user_id_alice',
          'encatch_user_signature_alice',
        ]),
      );

      await startSdk(api, apiKey: secureApiKey, keepStorage: true);
      api.clearRequests();
      expect(Encatch.isIdentified, isTrue);
      expect(Encatch.userName, 'alice');

      await Encatch.trackEvent('after-restart');
      await settle();
      final event = requestsAs(api, 'alice', 'track-event').single;
      expect(event.status, 200);
      expect(event.headers['x-user-signature'], isNotNull);
    });
  });
}
