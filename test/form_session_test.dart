// Step 10: closing a survey with its X before the final submit is a
// dismissal (for a visitor too, who sends dismiss-form but no survey event),
// and survey events carry the form's id even when the survey page
// sends an empty one. On 1.1.2 the X sent nothing and the ids were empty (seen
// on a device and on the DEV API).
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:encatch_flutter/src/form_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

/// What the real survey page sends: an empty form id and, on close, no
/// `feedbackConfigurationId`.
const _noId = '';
const _closeData = <String, dynamic>{'hasThankYouScreen': true};

/// Records the events the app would get through `Encatch.on`.
class AppEvents {
  AppEvents() {
    Encatch.on((type, payload) => seen.add((type, payload.formId)));
  }
  final List<(EventType, String?)> seen = [];
  List<EventType> get types => seen.map((e) => e.$1).toList();
}

/// A survey the user was shown: show-form has been answered and the page has
/// reported `form:show`.
FormSession openSurvey(FakeAsync async, FakeApi api) {
  Encatch.showForm(defaultFormId);
  async.flushMicrotasks();
  final session = FormSession(defaultFormId)..show(_noId, const {});
  async.flushMicrotasks();
  return session;
}

void main() {
  group('an X-close before the final submit is a dismissal', () {
    testFake('on the first screen', (async, api) {
      identify(async, 'alice');
      final events = AppEvents();
      final session = openSurvey(async, api);
      api.clearRequests();

      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));

      expect(eventsOf(api), ['form:dismissed']);
      final surveyEvent = api.of('track-event').single;
      expect(surveyEvent.status, 200);
      expect(surveyEvent.body['feedbackConfigurationId'], defaultFormId);

      final dismiss = api.of('dismiss-form').single;
      expect(dismiss.status, 200);
      expect(dismiss.body['formConfigurationId'], defaultFormId);
      expect(dismiss.userName, 'alice');

      expect(events.types, contains(EventType.formClose));
      expect(events.seen, contains((EventType.formDismissed, defaultFormId)));
    });

    testFake('mid-form, after a partial submit', (async, api) {
      identify(async, 'alice');
      final session = openSurvey(async, api);
      session.started(_noId, const {});
      session.submit(_noId, const {'isPartialSubmit': true});
      async.flushMicrotasks();
      api.clearRequests();

      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expect(api.count('dismiss-form'), 1);
      expect(eventsOf(api), ['form:dismissed']);
    });

    testFake('a second close message changes nothing', (async, api) {
      identify(async, 'alice');
      final session = openSurvey(async, api);
      api.clearRequests();
      session.close(_noId, _closeData);
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expect(api.count('dismiss-form'), 1);
      expect(eventsOf(api), ['form:dismissed']);
    });

    testFake('a visitor: dismiss-form only, no survey event', (async, api) {
      final events = AppEvents();
      final session = openSurvey(async, api);
      api.clearRequests();

      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));

      expect(api.count('track-event'), 0);
      final dismiss = api.requests.single;
      expect(dismiss.endpoint, 'dismiss-form');
      expect(dismiss.status, 200);
      expect(dismiss.body['formConfigurationId'], defaultFormId);
      expect(dismiss.userName, isNull);
      expect(dismiss.userId, isNull);

      expect(events.types, contains(EventType.formClose));
      expect(events.seen, contains((EventType.formDismissed, defaultFormId)));
    });

    testFake('a visitor: a second close message changes nothing', (async, api) {
      final session = openSurvey(async, api);
      api.clearRequests();
      session.close(_noId, _closeData);
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expect(api.count('dismiss-form'), 1);
      expect(api.count('track-event'), 0);
    });
  });

  group('not a dismissal', () {
    void expectNoDismissal(FakeApi api, AppEvents events) {
      expect(api.count('dismiss-form'), 0);
      expect(eventsOf(api), isNot(contains('form:dismissed')));
      expect(events.types, isNot(contains(EventType.formDismissed)));
    }

    testFake('closing on the thank-you screen, after the final submit', (
      async,
      api,
    ) {
      identify(async, 'alice');
      final events = AppEvents();
      final session = openSurvey(async, api);
      session.submit(_noId, const {'isPartialSubmit': false});
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expectNoDismissal(api, events);
      expect(events.types, contains(EventType.formClose));
    });

    testFake('closing after the form completed', (async, api) {
      identify(async, 'alice');
      final events = AppEvents();
      final session = openSurvey(async, api);
      session.complete(_noId, const {});
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expectNoDismissal(api, events);
      expect(eventsOf(api), contains('form:complete'));
    });

    testFake('"remind me later"', (async, api) {
      identify(async, 'alice');
      final events = AppEvents();
      final session = openSurvey(async, api);
      session.remindMeLater(_noId, const {});
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expectNoDismissal(api, events);
      expect(eventsOf(api), contains('form:remindmelater'));
      expect(events.types, contains(EventType.formRemindMeLater));
    });

    testFake('a call-to-action button', (async, api) {
      identify(async, 'alice');
      final events = AppEvents();
      final session = openSurvey(async, api);
      session.ctaTriggered(_noId, const {'action': 'redirect_external'});
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expectNoDismissal(api, events);
    });

    testFake('a visitor closing on the thank-you screen', (async, api) {
      final events = AppEvents();
      final session = openSurvey(async, api);
      api.clearRequests();
      session.submit(_noId, const {'isPartialSubmit': false});
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expect(api.requests, isEmpty);
      expect(events.types, isNot(contains(EventType.formDismissed)));
      expect(events.types, contains(EventType.formClose));
    });

    testFake('a visitor choosing "remind me later"', (async, api) {
      final events = AppEvents();
      final session = openSurvey(async, api);
      api.clearRequests();
      session.remindMeLater(_noId, const {});
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));
      expect(api.requests, isEmpty);
      expect(events.types, isNot(contains(EventType.formDismissed)));
    });
  });

  group('form ids', () {
    testFake('every app event carries the id when the page sends none', (
      async,
      api,
    ) {
      identify(async, 'alice');
      final events = AppEvents();
      final session = openSurvey(async, api);
      session.started(_noId, const {});
      session.sectionChange(_noId, const {'sectionIndex': 1});
      session.answered(_noId, const {});
      session.submit(_noId, const {'isPartialSubmit': true});
      session.error(_noId, const {'message': 'x'});
      session.close(_noId, _closeData);
      async.elapse(const Duration(seconds: 2));

      expect(events.seen, isNotEmpty);
      for (final (type, formId) in events.seen) {
        expect(formId, defaultFormId, reason: '$type');
      }
      expect(
        events.types.toSet(),
        containsAll([
          EventType.formShow,
          EventType.formStarted,
          EventType.formSectionChange,
          EventType.formAnswered,
          EventType.formSubmit,
          EventType.formError,
          EventType.formClose,
          EventType.formDismissed,
        ]),
      );
    });

    testFake('survey events sent to the server carry the id too', (async, api) {
      identify(async, 'alice');
      final session = openSurvey(async, api);
      session.started(_noId, const {});
      session.answered(_noId, const {});
      session.answered(_noId, const {});
      session.complete(_noId, const {});
      async.elapse(const Duration(seconds: 2));

      expect(eventsOf(api), [
        'form:show',
        'form:started',
        'form:answered', // the first answer only
        'form:complete',
      ]);
      for (final r in api.of('track-event')) {
        expect(r.body['feedbackConfigurationId'], defaultFormId, reason: '$r');
      }
    });

    test('an id the page does send wins', () {
      final session = FormSession(defaultFormId);
      expect(session.formIdFor('from-page', const {}), 'from-page');
      expect(
        session.formIdFor('', const {'feedbackConfigurationId': 'from-data'}),
        'from-data',
      );
      expect(
        session.formIdFor('', const {'feedbackConfigurationId': ''}),
        defaultFormId,
      );
      expect(session.formIdFor('', const {}), defaultFormId);
    });
  });
}
