/// Schedules exit_form completion CTAs after form:complete when the WebView
/// is torn down before a WebView setTimeout can fire (inline forms).
library;

import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

import 'encatch.dart';
import 'types.dart';

/// Wire-format payload forwarded from the form engine via form:complete.
class PendingCompletionCta {
  const PendingCompletionCta({
    required this.action,
    required this.surface,
    required this.trigger,
    required this.autoTriggerDelayMs,
    this.url,
    this.route,
  });

  final String action;
  final String? url;
  final String? route;
  final String surface;
  final String trigger;
  final int autoTriggerDelayMs;

  static PendingCompletionCta? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final action = map['action'];
    if (action is! String || action.isEmpty) return null;
    final delayRaw = map['autoTriggerDelayMs'];
    final delayMs = delayRaw is num ? delayRaw.toInt() : 0;
    return PendingCompletionCta(
      action: action,
      url: map['url'] as String?,
      route: map['route'] as String?,
      surface: (map['surface'] as String?) ?? 'inApp',
      trigger: (map['trigger'] as String?) ?? 'auto',
      autoTriggerDelayMs: delayMs < 0 ? 0 : delayMs,
    );
  }

  Map<String, dynamic> toEventData() => {
        'action': action,
        if (url != null) 'url': url,
        if (route != null) 'route': route,
        'surface': surface,
        'trigger': trigger,
      };
}

/// Native timer keyed by formId; cancels on showForm / dismissForm.
class PendingCompletionCtaScheduler {
  PendingCompletionCtaScheduler._();

  static final Map<String, Timer> _timers = {};

  static void schedule(String formId, PendingCompletionCta pending) {
    cancel(formId);
    final delayMs = pending.autoTriggerDelayMs;
    if (delayMs <= 0) {
      _execute(formId, pending);
      return;
    }
    _timers[formId] = Timer(Duration(milliseconds: delayMs), () {
      _timers.remove(formId);
      _execute(formId, pending);
    });
  }

  static void cancel(String formId) {
    _timers.remove(formId)?.cancel();
  }

  static void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  static void _execute(String formId, PendingCompletionCta pending) {
    final action = pending.action;
    if (action == 'dismiss') return;

    final data = pending.toEventData();

    if (action == 'app_navigate') {
      Encatch.emitEvent(
        EventType.formCtaTriggered,
        EventPayload(
          formId: formId,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          data: data,
        ),
      );
      return;
    }

    if ((action == 'redirect_internal' || action == 'redirect_external') &&
        pending.url != null) {
      final uri = Uri.tryParse(pending.url!);
      if (uri != null) {
        final mode = action == 'redirect_internal'
            ? LaunchMode.inAppBrowserView
            : LaunchMode.externalApplication;
        launchUrl(uri, mode: mode).catchError((Object e) {
          // ignore: avoid_print
          print(
            '[Encatch] pendingCompletionCta: failed to open URL ($action): $e',
          );
          return false;
        });
      }
      Encatch.emitEvent(
        EventType.formCtaTriggered,
        EventPayload(
          formId: formId,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          data: data,
        ),
      );
    }
  }
}
