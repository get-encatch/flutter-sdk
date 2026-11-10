// Step 4 (show-form guard): one survey at a time. These failed on 1.1.2.
import 'package:encatch_flutter/encatch_flutter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

void main() {
  testFake('eighteen visits to a survey screen show the survey once', (
    async,
    api,
  ) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    api.scenario.screenTriggers = {
      '/checkout': const SurveyTrigger(defaultFormId),
    };
    // Each call finishes before the next, as when an app re-tracks the screen
    // on every rebuild. 1.1.2 sends all eighteen, and a show-form for each.
    for (var i = 0; i < 18; i++) {
      Encatch.trackScreen('/checkout');
      async.flushMicrotasks();
    }
    async.elapse(const Duration(seconds: 5));
    expect(api.count('track-screen'), 1);
    expect(api.count('show-form'), 1);
    expect(api.count('show-form', status: 404), 0);
    expect(presenter.shown, hasLength(1));
    presenter.dispose();
  });

  testFake('an automatic survey is ignored while one is open', (async, api) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    api.scenario.screenTriggers = {
      '/a': const SurveyTrigger(defaultFormId),
      '/b': const SurveyTrigger(secondFormId),
    };
    Encatch.trackScreen('/a');
    async.elapse(const Duration(seconds: 2));
    expect(presenter.shown, hasLength(1));

    Encatch.trackScreen('/b');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('show-form'), 1, reason: 'a survey is already open');

    // Once the user closes it, the next automatic survey can show.
    presenter.close();
    Encatch.trackScreen('/b');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('show-form'), 2);
    expect(presenter.shown.last.formId, secondFormId);
    presenter.dispose();
  });

  testFake('showForm for the open form is ignored; another form replaces it', (
    async,
    api,
  ) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    Encatch.showForm(defaultFormId);
    async.flushMicrotasks();
    expect(presenter.shown, hasLength(1));

    Encatch.showForm(defaultFormId);
    Encatch.showForm(defaultFormId);
    async.flushMicrotasks();
    expect(api.count('show-form'), 1, reason: 'answers in progress are kept');
    expect(presenter.shown, hasLength(1));

    Encatch.showForm(secondFormId);
    async.flushMicrotasks();
    expect(api.count('show-form'), 2);
    expect(presenter.shown.last.formId, secondFormId);
    presenter.dispose();
  });

  testFake('repeated manual showForm calls while loading send one request', (
    async,
    api,
  ) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    api.scenario.latency = const Duration(milliseconds: 200);
    Encatch.showForm(defaultFormId);
    Encatch.showForm(defaultFormId);
    Encatch.showForm(defaultFormId);
    async.elapse(const Duration(seconds: 2));
    expect(api.count('show-form'), 1);
    expect(presenter.shown, hasLength(1));
    presenter.dispose();
  });

  testFake('only one delayed survey is pending at a time', (async, api) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    api.scenario.screenTriggers = {
      '/a': const SurveyTrigger(defaultFormId, onPageDelay: 5),
      '/b': const SurveyTrigger(defaultFormId, onPageDelay: 5),
      '/c': const SurveyTrigger(secondFormId, onPageDelay: 5),
    };
    Encatch.trackScreen('/a');
    async.elapse(const Duration(milliseconds: 1500));
    Encatch.trackScreen('/b');
    async.elapse(const Duration(milliseconds: 1500));
    Encatch.trackScreen('/c');
    expect(api.count('show-form'), 0, reason: 'still inside the delay');

    async.elapse(const Duration(seconds: 15));
    expect(api.count('show-form'), 1);
    expect(presenter.shown.single.formId, defaultFormId);
    presenter.dispose();
  });
  testFake('a 404 is not retried and leaves the next survey free to show', (
    async,
    api,
  ) {
    final presenter = FakePresenter();
    identify(async, 'alice');
    api.scenario.screenTriggers = {
      '/a': const SurveyTrigger(defaultFormId),
      '/b': const SurveyTrigger(secondFormId),
    };
    Encatch.trackScreen('/a');
    async.elapse(const Duration(seconds: 2));
    presenter.close();

    // The server keeps choosing the form; the second automatic show gets 404
    // ("not eligible now").
    Encatch.trackScreen('/home');
    Encatch.trackScreen('/a');
    async.elapse(const Duration(minutes: 2));
    expect(api.count('show-form'), 2);
    expect(api.of('show-form').last.status, 404);
    expect(presenter.shown, hasLength(1));

    Encatch.trackScreen('/b');
    async.elapse(const Duration(seconds: 2));
    expect(api.count('show-form'), 3);
    expect(presenter.shown.last.formId, secondFormId);
    presenter.dispose();
  });

  test('an interceptor veto leaves the next survey free to show', () {
    fakeAsync((async) {
      final api = FakeApi();
      final presenter = FakePresenter();
      var allow = false;
      startSdk(api, onBeforeShowForm: (_) async => allow);
      async.flushMicrotasks();
      identify(async, 'alice');
      api.scenario.screenTriggers = {
        '/a': const SurveyTrigger(defaultFormId),
        '/b': const SurveyTrigger(secondFormId),
      };
      Encatch.trackScreen('/a');
      async.elapse(const Duration(seconds: 2));
      expect(api.count('show-form'), 1);
      expect(presenter.shown, isEmpty, reason: 'vetoed');

      allow = true;
      Encatch.trackScreen('/b');
      async.elapse(const Duration(seconds: 2));
      expect(api.count('show-form'), 2);
      expect(presenter.shown.single.formId, secondFormId);

      presenter.dispose();
      stopSdk();
      async.flushMicrotasks();
    });
  });
}
