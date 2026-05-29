/// Inline slot registry for EncatchInlineForm.
///
/// Maintains an ordered list of mounted inline slots. When showForm fires,
/// [resolvePresentationTarget] determines whether it should render inline
/// (matching slot found) or fall through to the modal EncatchWebView.
///
/// Routing rules:
///  1. Exact match  — first slot whose formId matches the payload ids wins.
///  2. Wildcard     — first slot with no formId catches anything not exact-matched.
///  3. Modal        — no inline slot registered or none match.
library;

import 'package:uuid/uuid.dart';
import 'types.dart';

// ============================================================================
// Types
// ============================================================================

class InlineSlot {
  final String slotId;
  String? formId;

  InlineSlot({required this.slotId, this.formId});
}

sealed class PresentationTarget {}

class InlineTarget extends PresentationTarget {
  final String slotId;
  InlineTarget({required this.slotId});
}

class ModalTarget extends PresentationTarget {}

// ============================================================================
// Registry (module-level singleton, intentionally simple)
// ============================================================================

final _slots = <InlineSlot>[];
const _uuid = Uuid();

/// Register a new inline slot on widget mount.
/// Returns an opaque [slotId] to use with [unregisterInlineSlot] / [updateInlineSlot].
/// Registration order is preserved — first-registered wins for wildcard resolution.
String registerInlineSlot({String? formId}) {
  final slotId = _uuid.v7();
  _slots.add(InlineSlot(slotId: slotId, formId: formId));
  return slotId;
}

/// Remove an inline slot on widget dispose.
void unregisterInlineSlot(String slotId) {
  _slots.removeWhere((s) => s.slotId == slotId);
}

/// Update the formId of an existing slot without changing its registration order.
/// Called when the EncatchInlineForm formId prop changes after mount.
void updateInlineSlot(String slotId, {String? formId}) {
  final slot = _slots.firstWhere(
    (s) => s.slotId == slotId,
    orElse: () => throw StateError('Slot $slotId not found'),
  );
  slot.formId = formId;
}

// ============================================================================
// Resolver
// ============================================================================

/// Determine whether the given showForm payload should render inline or modal.
///
/// ID matching checks the slot's formId against:
///  - [formId]  (the slug/uuid passed by the caller, or formConfigurationId)
///  - [formConfig.feedbackConfigurationId]  (server-resolved id)
///
/// Single pass: find the first exact match, then the first wildcard; else modal.
PresentationTarget resolvePresentationTarget({
  required String formId,
  required ShowFormResponse formConfig,
}) {
  final candidateIds = <String>{
    if (formId.isNotEmpty) formId,
    if ((formConfig.feedbackConfigurationId).isNotEmpty)
      formConfig.feedbackConfigurationId,
  };

  InlineSlot? firstWildcard;

  for (final slot in _slots) {
    if (slot.formId != null && slot.formId!.isNotEmpty) {
      if (candidateIds.contains(slot.formId)) {
        return InlineTarget(slotId: slot.slotId);
      }
    } else {
      firstWildcard ??= slot;
    }
  }

  if (firstWildcard != null) {
    return InlineTarget(slotId: firstWildcard.slotId);
  }

  return ModalTarget();
}

// ============================================================================
// Test-only helpers
// ============================================================================

/// Exposed for testing only — do not use in production code.
List<InlineSlot> getSlotsForTesting() => List.unmodifiable(_slots);

/// Exposed for testing only — clears the registry.
void clearSlotsForTesting() => _slots.clear();
