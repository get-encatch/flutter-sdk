import 'package:flutter_test/flutter_test.dart';

import '../lib/src/form_presentation_registry.dart';
import '../lib/src/types.dart';

// Minimal ShowFormResponse stub for registry tests
ShowFormResponse _makeConfig(String feedbackConfigurationId) {
  return ShowFormResponse.fromJson({
    'feedbackConfigurationId': feedbackConfigurationId,
  });
}

void main() {
  setUp(clearSlotsForTesting);
  tearDown(clearSlotsForTesting);

  group('registerInlineSlot', () {
    test('returns unique slotIds', () {
      final a = registerInlineSlot();
      final b = registerInlineSlot();
      expect(a, isNot(equals(b)));
    });

    test('stores formId when provided', () {
      registerInlineSlot(formId: 'form-x');
      final slots = getSlotsForTesting();
      expect(slots.length, 1);
      expect(slots.first.formId, 'form-x');
    });

    test('stores null formId for wildcard slot', () {
      registerInlineSlot();
      final slots = getSlotsForTesting();
      expect(slots.first.formId, isNull);
    });
  });

  group('unregisterInlineSlot', () {
    test('removes the slot', () {
      final id = registerInlineSlot(formId: 'form-a');
      unregisterInlineSlot(id);
      expect(getSlotsForTesting(), isEmpty);
    });

    test('removes only the matching slot', () {
      final a = registerInlineSlot(formId: 'form-a');
      registerInlineSlot(formId: 'form-b');
      unregisterInlineSlot(a);
      final slots = getSlotsForTesting();
      expect(slots.length, 1);
      expect(slots.first.formId, 'form-b');
    });
  });

  group('updateInlineSlot', () {
    test('updates formId without changing registration order', () {
      final a = registerInlineSlot(formId: 'old');
      registerInlineSlot(formId: 'other');
      updateInlineSlot(a, formId: 'new');
      final slots = getSlotsForTesting();
      expect(slots.first.slotId, a);
      expect(slots.first.formId, 'new');
    });

    test('can clear formId to make wildcard', () {
      final id = registerInlineSlot(formId: 'form-x');
      updateInlineSlot(id);
      expect(getSlotsForTesting().first.formId, isNull);
    });
  });

  group('resolvePresentationTarget', () {
    test('returns ModalTarget when no slots registered', () {
      final result = resolvePresentationTarget(
        formId: 'form-x',
        formConfig: _makeConfig('form-x'),
      );
      expect(result, isA<ModalTarget>());
    });

    test('exact match wins over wildcard', () {
      registerInlineSlot(); // wildcard registered first
      final exactId = registerInlineSlot(formId: 'form-x');

      final result = resolvePresentationTarget(
        formId: 'form-x',
        formConfig: _makeConfig('form-x'),
      );
      expect(result, isA<InlineTarget>());
      expect((result as InlineTarget).slotId, exactId);
    });

    test('wildcard slot catches unmatched formId', () {
      final wildcardId = registerInlineSlot(); // wildcard

      final result = resolvePresentationTarget(
        formId: 'any-form',
        formConfig: _makeConfig('any-form'),
      );
      expect(result, isA<InlineTarget>());
      expect((result as InlineTarget).slotId, wildcardId);
    });

    test('first registered wildcard wins when multiple wildcards', () {
      final first = registerInlineSlot();
      registerInlineSlot();

      final result = resolvePresentationTarget(
        formId: 'x',
        formConfig: _makeConfig('x'),
      );
      expect((result as InlineTarget).slotId, first);
    });

    test('matches against feedbackConfigurationId from formConfig', () {
      final slotId = registerInlineSlot(formId: 'resolved-id');

      // formId arg is different but formConfig resolves to the slot's formId
      final result = resolvePresentationTarget(
        formId: 'original-slug',
        formConfig: _makeConfig('resolved-id'),
      );
      expect(result, isA<InlineTarget>());
      expect((result as InlineTarget).slotId, slotId);
    });

    test('returns ModalTarget when exact slots exist but none match', () {
      registerInlineSlot(formId: 'form-a');
      registerInlineSlot(formId: 'form-b');

      final result = resolvePresentationTarget(
        formId: 'form-c',
        formConfig: _makeConfig('form-c'),
      );
      expect(result, isA<ModalTarget>());
    });

    test('returns ModalTarget after all slots unregistered', () {
      final id = registerInlineSlot();
      unregisterInlineSlot(id);

      final result = resolvePresentationTarget(
        formId: 'any',
        formConfig: _makeConfig('any'),
      );
      expect(result, isA<ModalTarget>());
    });
  });
}
