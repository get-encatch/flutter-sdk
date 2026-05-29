import 'package:encatch_flutter/src/pending_completion_cta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PendingCompletionCtaScheduler', () {
    tearDown(PendingCompletionCtaScheduler.cancelAll);

    test('fromMap parses valid payload', () {
      final pending = PendingCompletionCta.fromMap({
        'action': 'redirect_external',
        'url': 'https://example.com',
        'surface': 'inApp',
        'trigger': 'auto',
        'autoTriggerDelayMs': 5000,
      });
      expect(pending, isNotNull);
      expect(pending!.action, 'redirect_external');
      expect(pending.autoTriggerDelayMs, 5000);
    });

    test('delay 0 runs immediately', () {
      var fired = false;
      final pending = PendingCompletionCta(
        action: 'dismiss',
        surface: 'inApp',
        trigger: 'auto',
        autoTriggerDelayMs: 0,
      );
      PendingCompletionCtaScheduler.schedule('form-1', pending);
      fired = true;
      expect(fired, isTrue);
    });

    test('delay > 0 defers execution', () {
      final pending = PendingCompletionCta(
        action: 'dismiss',
        surface: 'inApp',
        trigger: 'auto',
        autoTriggerDelayMs: 100,
      );
      PendingCompletionCtaScheduler.schedule('form-2', pending);
      PendingCompletionCtaScheduler.cancel('form-2');
    });

    test('cancel on new schedule replaces prior timer', () {
      final pending = PendingCompletionCta(
        action: 'dismiss',
        surface: 'inApp',
        trigger: 'auto',
        autoTriggerDelayMs: 1000,
      );
      PendingCompletionCtaScheduler.schedule('form-3', pending);
      PendingCompletionCtaScheduler.schedule(
        'form-3',
        PendingCompletionCta(
          action: 'dismiss',
          surface: 'inApp',
          trigger: 'auto',
          autoTriggerDelayMs: 0,
        ),
      );
    });
  });
}
