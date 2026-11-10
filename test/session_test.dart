// Step 11 (ping and session) and step 12b (Q&A streaming).
// Fails on 1.1.2 until the fixes land.
@Tags(['pending-fix'])
library;

import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  group('step 11: a stopped or paused session stays quiet', () {
    testFake('stopSession: a later reply does not restart the ping', (
      async,
      api,
    ) {
      identify(async, 'alice');
      Encatch.stopSession();
      async.flushMicrotasks();
      api.clearRequests();

      // The app's own call still goes out; its reply carries pingAgainIn.
      Encatch.trackEvent('after-stop');
      async.elapse(const Duration(minutes: 3));
      expect(eventsOf(api), ['after-stop']);
      expect(api.count('ping'), 0);
    });

    testFake('pauseSession: a later reply does not restart the ping', (
      async,
      api,
    ) {
      identify(async, 'alice');
      Encatch.pauseSession();
      api.clearRequests();

      Encatch.trackEvent('while-paused');
      async.elapse(const Duration(minutes: 3));
      expect(api.count('ping'), 0);

      Encatch.resumeSession();
      async.elapse(const Duration(minutes: 1));
      expect(api.count('ping'), greaterThanOrEqualTo(1));
    });

    testFake('stopSession cancels a survey that is waiting to show', (
      async,
      api,
    ) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      api.scenario.screenTriggers = {
        '/later': const SurveyTrigger(defaultFormId, onPageDelay: 10),
      };
      Encatch.trackScreen('/later');
      async.elapse(const Duration(seconds: 2));
      Encatch.stopSession();
      async.elapse(const Duration(seconds: 30));
      expect(api.count('show-form'), 0);
      expect(presenter.shown, isEmpty);
      presenter.dispose();
    });

    testWidgets('a stopped session stays stopped after an app restart', (
      tester,
    ) async {
      final api = FakeApi();
      addTearDown(stopSdk);
      await startSdk(api);
      await Encatch.startSession();
      await Encatch.stopSession();

      // Restart: memory is gone, storage is kept, the provider initialises.
      await prepareSdk(api, keepStorage: true);
      api.clearRequests();
      final observer = EncatchNavigatorObserver();
      await tester.pumpWidget(
        const EncatchProvider(
          apiKey: defaultApiKey,
          config: EncatchConfig(apiBaseUrl: fakeBaseUrl),
          child: SizedBox(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      observer.didPush(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/home'),
          pageBuilder: (_, _, _) => const SizedBox(),
        ),
        null,
      );
      await tester.pump(const Duration(seconds: 90));
      expect(api.count('ping'), 0, reason: 'no session start at launch');
      expect(api.count('track-screen'), 0, reason: 'no automatic screens');

      // startSession() turns it back on and sends the current screen.
      await Encatch.startSession();
      await tester.pump(const Duration(seconds: 1));
      expect(api.count('ping'), 1);
      expect(screensOf(api), ['/home']);

      await stopSdk();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('step 12b: Q&A with AI', () {
    tearDown(stopSdk);

    test('the answer arrives piece by piece', () async {
      final api = FakeApi();
      await startSdk(api);
      final pieces = <String>[];
      final result = await Encatch.streamQnaWithAi(
        const QnaWithAiRequest(
          feedbackConfigurationId: defaultFormId,
          questionId: 'q1',
          conversation: [
            QnaWithAiConversationTurn(question: 'Why?', answer: ''),
          ],
        ),
        onChunk: pieces.add,
      );
      const answer = 'This answer was streamed by the fake.';
      expect(result.answer, answer);
      expect(pieces.length, greaterThan(1), reason: 'one call per piece');
      expect(pieces.join(), answer);
    });
  });
}
