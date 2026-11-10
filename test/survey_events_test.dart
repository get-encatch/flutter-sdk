// Steps 7 and 8: visitors send no survey events, and a survey the server
// chooses in any reply is shown. These failed on 1.1.2.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

const _surveyEvents = [
  'form:show',
  'form:started',
  'form:answered',
  'form:complete',
  'form:remindmelater',
];

void main() {
  group('step 7: survey events', () {
    testFake('a visitor sends no survey events', (async, api) {
      for (final name in _surveyEvents) {
        Encatch.trackFormEvent(name, defaultFormId);
      }
      async.elapse(const Duration(seconds: 2));
      expect(api.count('track-event'), 0);
      expect(api.requests.where((r) => r.status == 403), isEmpty);
    });

    testFake('none are sent while the first identify is in flight', (
      async,
      api,
    ) {
      api.scenario.latency = const Duration(milliseconds: 300);
      Encatch.identifyUser('alice');
      async.elapse(const Duration(milliseconds: 100));
      Encatch.trackFormEvent('form:show', defaultFormId);
      async.elapse(const Duration(seconds: 2));
      expect(eventsOf(api), isEmpty);
    });
  });

  group('step 7: identified users', () {
    testFake('every survey event is sent, "remind me later" included', (
      async,
      api,
    ) {
      identify(async, 'alice');
      api.clearRequests();
      for (final name in _surveyEvents) {
        Encatch.trackFormEvent(name, defaultFormId);
      }
      async.elapse(const Duration(seconds: 2));
      expect(eventsOf(api), _surveyEvents);
      for (final r in api.of('track-event')) {
        expect(r.status, 200);
        expect(r.userName, 'alice');
        expect(r.userId, api.expectedUserId('alice'));
      }
    });

    testFake("a survey chosen in a survey event's reply waits its turn", (
      async,
      api,
    ) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      Encatch.showForm(defaultFormId);
      async.flushMicrotasks();
      expect(presenter.shown, hasLength(1));

      // The reply to this survey's own form:show picks another survey.
      api.scenario.eventTriggers = {
        'form:show': const SurveyTrigger(secondFormId),
      };
      Encatch.trackFormEvent('form:show', defaultFormId);
      async.elapse(const Duration(seconds: 2));
      expect(api.count('show-form'), 1, reason: 'a survey is open');
      presenter.dispose();
    });
  });

  group('step 8: a survey chosen in any reply is shown', () {
    testFake('identify reply', (async, api) {
      final presenter = FakePresenter();
      api.scenario.identifyTrigger = const SurveyTrigger(defaultFormId);
      Encatch.identifyUser('alice');
      async.elapse(const Duration(seconds: 2));
      expect(api.count('show-form'), 1);
      final show = api.of('show-form').single;
      expect(show.body['formSlugOrId'], defaultFormId);
      expect(show.body['triggerType'], 'automatic');
      expect(presenter.shown.single.formId, defaultFormId);
      presenter.dispose();
    });

    testFake('track-event reply', (async, api) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      api.scenario.eventTriggers = {
        'purchase': const SurveyTrigger(defaultFormId),
      };
      Encatch.trackEvent('purchase');
      async.elapse(const Duration(seconds: 2));
      expect(api.count('show-form'), 1);
      expect(presenter.shown.single.formId, defaultFormId);
      presenter.dispose();
    });

    testFake('ping reply', (async, api) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      api.scenario.pingTrigger = const SurveyTrigger(defaultFormId);
      // A new user is told to ping again in 10 s.
      async.elapse(const Duration(seconds: 12));
      expect(api.count('ping'), greaterThanOrEqualTo(1));
      expect(api.count('show-form'), 1);
      expect(presenter.shown.single.formId, defaultFormId);
      presenter.dispose();
    });

    testFake('onPageDelay is honoured for an event-triggered survey', (
      async,
      api,
    ) {
      final presenter = FakePresenter();
      identify(async, 'alice');
      api.scenario.eventTriggers = {
        'purchase': const SurveyTrigger(defaultFormId, onPageDelay: 5),
      };
      Encatch.trackEvent('purchase');
      async.elapse(const Duration(seconds: 4));
      expect(api.count('show-form'), 0);
      async.elapse(const Duration(seconds: 2));
      expect(api.count('show-form'), 1);
      presenter.dispose();
    });
  });
}
