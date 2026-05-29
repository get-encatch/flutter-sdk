/// EncatchInlineForm
///
/// Renders the Encatch form inline within the host layout — no modal, no overlay.
/// Place it anywhere in a screen's widget tree.
///
/// Routing (resolved before this widget receives anything):
///  - Exact match: EncatchInlineForm(formId: 'slug') catches showForm('slug')
///  - Wildcard:    EncatchInlineForm() catches any form not claimed by an exact slot
///  - Fallback:    when no inline slot is registered, EncatchWebView (modal) takes over
///
/// Navigation / tab focus:
///  - Pass enabled: ModalRoute.of(context)?.isCurrent ?? true so that background
///    tab screens do not intercept showForm meant for the modal or another screen.
///  - Alternatively, only mount EncatchInlineForm on the currently active route.
///
/// ScrollView embedding:
///  - WebView internal scroll is disabled; the host ScrollView scrolls the widget.
///  - Normal form content grows to its reported height so long forms remain reachable.
///  - QnA/Scheduler overlays freeze to a capped height instead of expanding.
///
/// Single-active-form contract:
///  - When a showForm targets a different presenter, this widget clears its
///    active payload so only one form is ever visible at a time.
///  - On dispose while a form is active: setFormVisible(false) is called;
///    no dismissForm API call is made.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'encatch.dart';
import 'encatch_form_webview_bridge.dart';
import 'form_presentation_registry.dart';
import 'form_webview_helpers.dart';
import 'form_webview_skeleton.dart';
import 'types.dart';

// Height used as a placeholder before the first form:resize arrives.
// Large enough for the skeleton rows to render; replaced by the real
// content height once form:resize fires.
const double _kLoadingSkeletonHeight = 300;

class EncatchInlineForm extends StatefulWidget {
  /// When set, this slot only catches showForm() calls for this exact form id
  /// (slug or uuid). When omitted, this is a wildcard slot that catches any
  /// unmatched form.
  final String? formId;

  /// When false, the inline slot is unregistered so showForm falls through to
  /// the modal. Pass `enabled: ModalRoute.of(context)?.isCurrent ?? true` to
  /// prevent background tab screens from stealing showForm.
  final bool enabled;

  /// Optional minimum height floor in points after the first form:resize.
  /// Defaults to 0 (height comes from form content only). Before the first
  /// resize, a placeholder keeps the WebView mountable for the loading overlay.
  final double minHeight;

  /// Outer container decoration (e.g. border radius, border, shadow).
  final BoxDecoration? decoration;

  /// Called when an in-form overlay (QnA with AI, Scheduler) opens or closes.
  /// Host apps can use this to adjust outer ScrollView scroll/keyboard behaviour.
  final ValueChanged<bool>? onOverlayOpenChange;

  const EncatchInlineForm({
    super.key,
    this.formId,
    this.enabled = true,
    this.minHeight = 0,
    this.decoration,
    this.onOverlayOpenChange,
  });

  @override
  State<EncatchInlineForm> createState() => _EncatchInlineFormState();
}

class _EncatchInlineFormState extends State<EncatchInlineForm> {
  String? _slotId;
  ShowFormPayload? _activePayload;

  // Height driven by form:resize messages.
  double _contentHeight = 0;

  // Frozen height while QnA/Scheduler overlay is open.
  double? _frozenHeight;
  bool _overlayActive = false;

  // WebView readiness — drives skeleton visibility.
  bool _webViewReady = false;

  StreamSubscription<ShowFormPayload>? _showSub;
  StreamSubscription<DismissPayload>? _dismissSub;

  // ============================================================================
  // Slot registration
  // ============================================================================

  void _registerSlot() {
    if (_slotId != null) return;
    _slotId = registerInlineSlot(formId: widget.formId);
  }

  void _unregisterSlot() {
    if (_slotId == null) return;
    unregisterInlineSlot(_slotId!);
    _slotId = null;
  }

  // ============================================================================
  // Lifecycle
  // ============================================================================

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _registerSlot();
    _showSub = Encatch.onShowForm.listen(_onShowForm);
    _dismissSub = Encatch.onDismissForm.listen(_onDismissForm);
  }

  @override
  void didUpdateWidget(EncatchInlineForm old) {
    super.didUpdateWidget(old);

    // enabled changed
    if (widget.enabled != old.enabled) {
      if (widget.enabled) {
        _registerSlot();
      } else {
        _unregisterSlot();
        _clearActiveForm();
      }
    }

    // formId changed — update existing slot without changing order
    if (widget.formId != old.formId && _slotId != null) {
      updateInlineSlot(_slotId!, formId: widget.formId);
    }
  }

  @override
  void dispose() {
    _showSub?.cancel();
    _dismissSub?.cancel();
    _unregisterSlot();
    if (_activePayload != null) {
      // Form was active on unmount — clear visibility; no dismiss API call.
      Encatch.setFormVisible(false);
    }
    super.dispose();
  }

  // ============================================================================
  // Stream handlers
  // ============================================================================

  void _onShowForm(ShowFormPayload payload) {
    final mySlotId = _slotId;

    if (payload.presentation == FormPresentation.inline &&
        payload.inlineSlotId == mySlotId) {
      // This event is for us — load the form.
      setState(() {
        _activePayload = payload;
        _contentHeight = 0;
        _frozenHeight = null;
        _overlayActive = false;
        _webViewReady = false;
      });
      Encatch.setFormVisible(true);
    } else {
      // A different presenter is taking over — clear our payload to maintain
      // the single-active-form contract.
      if (_activePayload != null) {
        setState(() {
          _activePayload = null;
          _contentHeight = 0;
          _frozenHeight = null;
          _overlayActive = false;
          _webViewReady = false;
        });
        Encatch.setFormVisible(false);
      }
    }
  }

  void _onDismissForm(DismissPayload _) {
    if (_activePayload == null) return;
    _clearActiveForm();
  }

  void _clearActiveForm() {
    if (_activePayload != null) {
      Encatch.setFormVisible(false);
    }
    setState(() {
      _activePayload = null;
      _contentHeight = 0;
      _frozenHeight = null;
      _overlayActive = false;
      _webViewReady = false;
    });
  }

  // ============================================================================
  // Bridge callbacks
  // ============================================================================

  void _onBridgeReady() {
    if (!mounted) return;
    setState(() => _webViewReady = true);
  }

  void _onBridgeClose() {
    _clearActiveForm();
  }

  void _onHeightChange(double h) {
    if (_overlayActive) return; // ignore resizes while overlay is frozen
    final next = widget.minHeight > 0
        ? h.clamp(widget.minHeight, double.infinity)
        : h;
    if ((next - _contentHeight).abs() > 1) {
      setState(() => _contentHeight = next);
    }
  }

  void _onForceFullHeight(bool force) {
    if (force == _overlayActive) return;
    setState(() {
      _overlayActive = force;
      if (force) {
        // Freeze at the current content height so the widget doesn't expand
        // to full screen while an overlay is open.
        final base = _contentHeight > 0
            ? _contentHeight
            : widget.minHeight > 0
            ? widget.minHeight
            : _kLoadingSkeletonHeight;
        final screenH = MediaQuery.of(context).size.height;
        _frozenHeight = base.clamp(0, screenH * 0.8);
      } else {
        _frozenHeight = null;
      }
    });
    widget.onOverlayOpenChange?.call(force);
  }

  // ============================================================================
  // Computed height
  // ============================================================================

  double get _widgetHeight {
    if (_frozenHeight != null) return _frozenHeight!;
    if (_contentHeight > 0) {
      return widget.minHeight > 0
          ? _contentHeight.clamp(widget.minHeight, double.infinity)
          : _contentHeight;
    }
    // Before first form:resize: use minHeight if set, else skeleton height.
    return widget.minHeight > 0 ? widget.minHeight : _kLoadingSkeletonHeight;
  }

  // ============================================================================
  // Build
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    if (_activePayload == null) {
      // Slot is registered but no form is active — render zero size.
      return widget.decoration != null
          ? Container(height: 0, decoration: widget.decoration)
          : const SizedBox(height: 0);
    }

    final formTheme = resolveFormWebViewTheme(
      _activePayload,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
      debugLabel: 'EncatchInlineForm',
    );
    final backgroundColor = formTheme.backgroundColor;
    final brightness = formTheme.activeMode;

    final child = SizedBox(
      width: double.infinity,
      height: _widgetHeight,
      child: Stack(
        children: [
          EncatchFormWebViewBridge(
            key: ObjectKey(_activePayload),
            payload: _activePayload!,
            logTag: 'EncatchInlineForm',
            presentation: FormPresentation.inline,
            onReady: _onBridgeReady,
            onClose: _onBridgeClose,
            onHeightChange: _onHeightChange,
            onForceFullHeight: _onForceFullHeight,
          ),
          if (!_webViewReady)
            Positioned.fill(
              child: FormWebViewSkeleton(
                backgroundColor: backgroundColor,
                activeMode: brightness,
              ),
            ),
        ],
      ),
    );

    if (widget.decoration != null) {
      return Container(decoration: widget.decoration, child: child);
    }
    return child;
  }
}
