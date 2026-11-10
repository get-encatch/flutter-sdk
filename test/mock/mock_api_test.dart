// The same behaviour as the unit tests, checked over real HTTP against the Node
// mock API (e2e/mock-api), which copies the server contract. It proves the Dart
// fake used by the unit tests has not drifted from the mock.
//
// Skipped by default: it needs this repo's mock running on port 8797.
//
//   cd e2e/mock-api && pnpm dev -- --port 8797
//   flutter test --run-skipped --tags mock
//
// Never point this at port 8787 (the React Native SDK's mock) or a real server.
@Tags(['mock'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/internals.dart' as internals;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/harness.dart'
    show
        FakePresenter,
        defaultApiKey,
        defaultFormId,
        secureApiKey,
        secureSessionApiKey;

const _mock = 'http://127.0.0.1:8797';

/// One request the mock logged.
class Logged {
  Logged(Map<String, dynamic> json)
    : endpoint = json['endpoint'] as String? ?? '',
      status = json['status'] as int,
      body = json['body'] is Map<String, dynamic>
          ? json['body'] as Map<String, dynamic>
          : const {},
      headers = {
        for (final e in (json['headers'] as Map<String, dynamic>).entries)
          e.key.toLowerCase(): '${e.value}',
      };
  final String endpoint;
  final int status;
  final Map<String, dynamic> body;
  final Map<String, String> headers;

  String? get userName => headers['x-user-name'];
  String? get userId => headers['x-user-id'];
  String? get eventName => body['eventName'] as String?;

  @override
  String toString() => '$endpoint $status name=$userName id=$userId';
}

/// The mock's control API (`/__mock/...`).
class MockControl {
  final http.Client _client = http.Client();

  Future<void> reset() => _client.post(Uri.parse('$_mock/__mock/reset'));

  Future<void> scenario(Map<String, dynamic> patch) async {
    final r = await _client.post(
      Uri.parse('$_mock/__mock/scenario'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(patch),
    );
    expect(r.statusCode, 200, reason: 'scenario rejected: ${r.body}');
  }

  Future<List<Logged>> requests([String? endpoint]) async {
    final r = await _client.get(Uri.parse('$_mock/__mock/requests?limit=5000'));
    final all = (jsonDecode(r.body) as List)
        .cast<Map<String, dynamic>>()
        .map(Logged.new)
        .where((l) => l.endpoint.isNotEmpty)
        .toList();
    return endpoint == null
        ? all
        : all.where((l) => l.endpoint == endpoint).toList();
  }

  Future<({String signature, String? time})> sign(
    String userName,
    String apiKey,
  ) async {
    final r = await _client.get(
      Uri.parse('$_mock/__mock/sign?userName=$userName&apiKey=$apiKey'),
    );
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      signature: json['signature'] as String,
      time: json['time'] as String?,
    );
  }
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  final mock = MockControl();

  /// A clean mock and a clean SDK pointed at it.
  Future<void> start({String apiKey = defaultApiKey}) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null; // the test binding blocks real HTTP otherwise
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/device_info'),
      (call) async => <String, dynamic>{},
    );
    await internals.resetSdkForTest?.call();
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Encatch test',
      packageName: 'com.encatch.test',
      version: '9.9.9',
      buildNumber: '1',
      buildSignature: '',
    );
    internals.sdkHttpClient = http.Client();
    await mock.reset();
    await Encatch.init(apiKey, config: const EncatchConfig(apiBaseUrl: _mock));
  }

  Future<void> identify(String userName) async {
    await Encatch.identifyUser(userName);
    await wait(400);
    expect(Encatch.userId, isNotNull, reason: 'identify did not complete');
  }

  setUpAll(() async {
    HttpOverrides.global = null;
    try {
      final r = await http.get(Uri.parse('$_mock/__mock/health'));
      expect(r.statusCode, 200);
    } catch (e) {
      fail(
        'The mock API is not running on port 8797. Start it with '
        '"cd e2e/mock-api && pnpm dev -- --port 8797". ($e)',
      );
    }
  });

  tearDown(() async {
    await internals.resetSdkForTest?.call();
  });

  test('a call made while another is in flight is still sent', () async {
    await start();
    await Encatch.identifyUser('alice');
    await Encatch.trackScreen('/home');
    await wait(1500);
    expect(await mock.requests('identify-user'), hasLength(1));
    expect(await mock.requests('track-screen'), hasLength(1));
  });

  test('twenty identical identifyUser calls send one request', () async {
    await start();
    for (var i = 0; i < 20; i++) {
      Encatch.identifyUser('alice');
    }
    await wait(1500);
    await Encatch.trackScreen('/nudge'); // 1.1.2 sends the stranded 19 here
    await wait(2500);
    expect(await mock.requests('identify-user'), hasLength(1));
  });

  test('twenty identical trackEvent calls send one request', () async {
    await start();
    await identify('alice');
    for (var i = 0; i < 20; i++) {
      Encatch.trackEvent('tap');
    }
    await wait(1500);
    await Encatch.trackScreen('/nudge');
    await wait(2500);
    final taps = (await mock.requests(
      'track-event',
    )).where((r) => r.eventName == 'tap');
    expect(taps, hasLength(1));
  });

  test('eighteen visits to a survey screen show the survey once', () async {
    await start();
    final presenter = FakePresenter();
    addTearDown(presenter.dispose);
    await identify('alice');
    await mock.scenario({
      'triggers': {
        'screens': {
          '/checkout': {'formId': defaultFormId},
        },
      },
    });
    for (var i = 0; i < 18; i++) {
      await Encatch.trackScreen('/checkout');
      await wait(150);
    }
    await wait(1500);
    final shows = await mock.requests('show-form');
    expect(await mock.requests('track-screen'), hasLength(1));
    expect(shows, hasLength(1));
    expect(shows.where((r) => r.status == 404), isEmpty);
    expect(presenter.shown, hasLength(1));
  });

  test('after a failed first identify, requests go out as a visitor', () async {
    await start();
    await mock.scenario({
      'allowTrackEventForVisitors': true,
      'faults': [
        {
          'endpoint': 'identify-user',
          'count': 1,
          'status': 429,
          'retryAfterSeconds': 1,
        },
      ],
    });
    await Encatch.identifyUser('alice');
    await wait(2500);
    await Encatch.trackEvent('after');
    await wait(1000);
    final event = (await mock.requests('track-event')).single;
    expect(event.userName, isNull);
    expect(event.userId, isNull);
    expect(event.status, 200);
    expect((await mock.requests()).where((r) => r.status == 401), isEmpty);
  });

  test('resetUser then identifyUser, neither awaited', () async {
    await start();
    await identify('alice');
    await mock.reset();

    Encatch.resetUser();
    Encatch.identifyUser('bob');
    await wait(1500);
    expect(Encatch.userName, 'bob');
    final identifies = await mock.requests('identify-user');
    expect(identifies, hasLength(1));
    expect(identifies.single.userName, 'bob');
    expect(identifies.single.userId, isNull);

    await Encatch.trackEvent('after');
    await wait(1000);
    final event = (await mock.requests('track-event')).single;
    expect(event.status, 200);
    expect(event.userName, 'bob');
    expect(event.userId, Encatch.userId);
    expect((await mock.requests()).where((r) => r.status == 401), isEmpty);
  });

  test('a signed identify passes the gateway check', () async {
    for (final key in [secureApiKey, secureSessionApiKey]) {
      await start(apiKey: key);
      final signed = await mock.sign('alice', key);
      await Encatch.identifyUser(
        'alice',
        options: IdentifyOptions(
          secure: SecureOptions(
            signature: signed.signature,
            generatedDateTimeinUTC: signed.time,
          ),
        ),
      );
      await wait(800);
      final request = (await mock.requests('identify-user')).single;
      expect(request.status, 200, reason: key);
      expect(Encatch.userId, isNotNull, reason: key);
    }
  });

  test(
    'a survey chosen in an identify, event or ping reply is shown',
    () async {
      // identify
      await start();
      var presenter = FakePresenter();
      await mock.scenario({
        'triggers': {
          'identify': {'formId': defaultFormId},
        },
      });
      await Encatch.identifyUser('alice');
      await wait(1200);
      expect(
        await mock.requests('show-form'),
        hasLength(1),
        reason: 'identify',
      );
      presenter.dispose();

      // track-event
      await start();
      presenter = FakePresenter();
      await identify('bob');
      await mock.scenario({
        'triggers': {
          'events': {
            'purchase': {'formId': defaultFormId},
          },
        },
      });
      await Encatch.trackEvent('purchase');
      await wait(1200);
      expect(await mock.requests('show-form'), hasLength(1), reason: 'event');
      presenter.dispose();

      // ping
      await start();
      presenter = FakePresenter();
      await identify('carol');
      await mock.scenario({
        'triggers': {
          'ping': {'formId': defaultFormId},
        },
      });
      await Encatch.startSession(); // pings straight away
      await wait(1200);
      expect(await mock.requests('show-form'), hasLength(1), reason: 'ping');
      presenter.dispose();
    },
  );

  test('a visitor sends no survey events', () async {
    await start();
    for (final name in ['form:show', 'form:started', 'form:complete']) {
      await Encatch.trackFormEvent(name, defaultFormId);
    }
    await wait(800);
    expect(await mock.requests('track-event'), isEmpty);
    expect((await mock.requests()).where((r) => r.status == 403), isEmpty);
  });

  test('a 429 pauses tracking calls for Retry-After, then resumes', () async {
    await start();
    await identify('alice');
    await mock.reset();
    await mock.scenario({
      'faults': [
        {
          'endpoint': 'track-event',
          'count': 1,
          'status': 429,
          'retryAfterSeconds': 3,
        },
      ],
    });
    await Encatch.trackEvent('a');
    await wait(600);
    await Encatch.trackEvent('b');
    await wait(1200);
    expect((await mock.requests('track-event')).map((r) => r.eventName), ['a']);

    await wait(2000);
    await Encatch.trackEvent('c');
    await wait(800);
    expect((await mock.requests('track-event')).map((r) => r.eventName), [
      'a',
      'c',
    ]);
  });

  test('"retries exhausted" in a reply resets the user', () async {
    await start();
    await identify('alice');
    await mock.scenario({
      'userPending': {'enabled': true, 'exhaustAfter': 1},
    });
    await Encatch.trackEvent('x');
    await wait(1000);
    expect(Encatch.userName, isNull);
  });

  test('a Q&A-with-AI answer arrives piece by piece', () async {
    await start();
    final pieces = <String>[];
    final result = await Encatch.streamQnaWithAi(
      const QnaWithAiRequest(
        feedbackConfigurationId: defaultFormId,
        questionId: 'q1',
        conversation: [QnaWithAiConversationTurn(question: 'Why?', answer: '')],
      ),
      onChunk: pieces.add,
    );
    expect(result.answer, isNotEmpty);
    expect(pieces.length, greaterThan(1));
    expect(pieces.join(), result.answer);
  });
}
