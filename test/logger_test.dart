// Step 12: the debug log masks secrets, and the SDK prints nothing itself.
import 'dart:io';

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/logger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  tearDown(() => EncatchLogger.sink = null);

  test('the debug log never contains the signature or the API key', () async {
    final lines = <String>[];
    EncatchLogger.sink = (output, _) => lines.add(output);
    final api = FakeApi();
    addTearDown(stopSdk);
    await startSdk(api, apiKey: secureSessionApiKey, debugMode: true);

    final signed = api.sign('alice', secureSessionApiKey);
    await Encatch.identifyUser(
      'alice',
      options: IdentifyOptions(
        secure: SecureOptions(
          signature: signed.signature,
          generatedDateTimeinUTC: signed.time,
        ),
      ),
    );
    await Encatch.trackEvent('after');
    await pumpEventQueue();

    final log = lines.join('\n');
    expect(log, contains('identify-user'), reason: 'requests are logged');
    expect(log, contains('userSignature'), reason: 'the field is shown');
    expect(log, isNot(contains(signed.signature)));
    expect(log, isNot(contains(secureSessionApiKey)));
  });

  test('nothing is logged at debug level unless debugMode is on', () async {
    final lines = <String>[];
    EncatchLogger.sink = (output, _) => lines.add(output);
    final api = FakeApi();
    addTearDown(stopSdk);
    await startSdk(api);
    await Encatch.identifyUser('alice');
    await Encatch.trackEvent('quiet');
    await pumpEventQueue();
    expect(lines, isEmpty);
  });

  test('the SDK source has no print statements', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue; // doc examples
        if (RegExp(r'(?<![A-Za-z_.])print\(').hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
